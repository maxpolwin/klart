/**
 * Auto-closes Linear tickets for vulnerabilities that are no longer detected.
 * Compares current scan results against open security tickets and closes
 * tickets whose vulnerability hashes no longer appear in the findings.
 */

const fs = require('fs');
const crypto = require('crypto');

const LINEAR_API_URL = 'https://api.linear.app/graphql';
const LINEAR_API_KEY = process.env.LINEAR_API_KEY;
const LINEAR_TEAM_ID = process.env.LINEAR_TEAM_ID;
const LINEAR_SECURITY_LABEL_ID = process.env.LINEAR_SECURITY_LABEL_ID;

async function linearRequest(query, variables = {}) {
  const response = await fetch(LINEAR_API_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': LINEAR_API_KEY
    },
    body: JSON.stringify({ query, variables })
  });

  const data = await response.json();

  if (data.errors) {
    console.error('Linear API errors:', JSON.stringify(data.errors, null, 2));
    throw new Error(`Linear API error: ${data.errors[0].message}`);
  }

  return data.data;
}

function generateVulnHash(vuln) {
  const key = `${vuln.ruleId}-${vuln.file}-${vuln.severity}`;
  return crypto.createHash('md5').update(key).digest('hex').substring(0, 8);
}

function parseTrivyResults() {
  const vulnerabilities = [];

  try {
    const trivyData = JSON.parse(fs.readFileSync('trivy-results.json', 'utf8'));

    for (const result of trivyData.Results || []) {
      const target = result.Target || 'unknown';

      for (const vuln of result.Vulnerabilities || []) {
        vulnerabilities.push({
          scanner: 'Trivy',
          severity: vuln.Severity,
          file: target,
          ruleId: vuln.VulnerabilityID
        });
      }
    }
  } catch (error) {
    console.log('ℹ️  No Trivy results found or error parsing:', error.message);
  }

  return vulnerabilities;
}

function parseSemgrepResults() {
  const vulnerabilities = [];

  try {
    const semgrepFiles = fs.readdirSync('.').filter(f =>
      f.startsWith('semgrep') && f.endsWith('.sarif')
    );

    for (const file of semgrepFiles) {
      const sarifData = JSON.parse(fs.readFileSync(file, 'utf8'));

      for (const run of sarifData.runs || []) {
        for (const result of run.results || []) {
          const location = result.locations?.[0]?.physicalLocation;
          const severity = result.level === 'error' ? 'HIGH' :
                          result.level === 'warning' ? 'MEDIUM' : 'LOW';

          vulnerabilities.push({
            scanner: 'Semgrep',
            severity: severity,
            file: location?.artifactLocation?.uri || 'unknown',
            ruleId: result.ruleId
          });
        }
      }
    }
  } catch (error) {
    console.log('ℹ️  No Semgrep results found or error parsing:', error.message);
  }

  return vulnerabilities;
}

async function getOpenSecurityTickets() {
  const tickets = [];
  let hasMore = true;
  let afterCursor = null;

  while (hasMore) {
    const query = `
      query OpenSecurityIssues($filter: IssueFilter!, $after: String) {
        issues(filter: $filter, first: 50, after: $after) {
          nodes {
            id
            identifier
            title
            state {
              type
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    `;

    const filter = {
      team: { id: { eq: LINEAR_TEAM_ID } },
      labels: { id: { eq: LINEAR_SECURITY_LABEL_ID } },
      state: { type: { nin: ['completed', 'canceled'] } }
    };

    const data = await linearRequest(query, {
      filter,
      after: afterCursor
    });

    tickets.push(...data.issues.nodes);
    hasMore = data.issues.pageInfo.hasNextPage;
    afterCursor = data.issues.pageInfo.endCursor;
  }

  return tickets;
}

function extractHashFromTitle(title) {
  const match = title.match(/\[([a-f0-9]{8})\]$/);
  return match ? match[1] : null;
}

async function closeTicket(ticket) {
  // First get the "Done" state for the team
  const statesQuery = `
    query TeamStates($teamId: String!) {
      team(id: $teamId) {
        states {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  `;

  const statesData = await linearRequest(statesQuery, { teamId: LINEAR_TEAM_ID });
  const doneState = statesData.team.states.nodes.find(s => s.type === 'completed');

  if (!doneState) {
    console.error(`❌ Could not find a completed state for team ${LINEAR_TEAM_ID}`);
    return false;
  }

  const mutation = `
    mutation CloseIssue($id: String!, $stateId: String!, $comment: CommentCreateInput!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) {
        success
      }
      commentCreate(input: $comment) {
        success
      }
    }
  `;

  const data = await linearRequest(mutation, {
    id: ticket.id,
    stateId: doneState.id,
    comment: {
      issueId: ticket.id,
      body: `✅ **Auto-closed:** This vulnerability is no longer detected in the latest security scan.\n\n*Closed automatically by GitHub Actions security workflow on ${new Date().toISOString().split('T')[0]}.*`
    }
  });

  return data.issueUpdate.success;
}

async function main() {
  if (!LINEAR_API_KEY || !LINEAR_TEAM_ID || !LINEAR_SECURITY_LABEL_ID) {
    console.log('⚠️  Linear credentials not configured. Skipping auto-close.');
    console.log('Please configure: LINEAR_API_KEY, LINEAR_TEAM_ID, LINEAR_SECURITY_LABEL_ID');
    return;
  }

  console.log('🔍 Parsing current scan results...');

  const trivyVulns = parseTrivyResults();
  const semgrepVulns = parseSemgrepResults();
  const allVulns = [...trivyVulns, ...semgrepVulns];

  const currentHashes = new Set(allVulns.map(v => generateVulnHash(v)));
  console.log(`📊 Current scan has ${allVulns.length} findings (${currentHashes.size} unique hashes)`);

  console.log('📋 Fetching open security tickets from Linear...');
  const openTickets = await getOpenSecurityTickets();
  console.log(`   Found ${openTickets.length} open security tickets`);

  let closed = 0;
  let stillOpen = 0;
  let noHash = 0;

  for (const ticket of openTickets) {
    const hash = extractHashFromTitle(ticket.title);

    if (!hash) {
      noHash++;
      continue;
    }

    if (!currentHashes.has(hash)) {
      console.log(`🔒 Closing ${ticket.identifier}: ${ticket.title.substring(0, 60)}...`);
      try {
        await closeTicket(ticket);
        closed++;
      } catch (error) {
        console.error(`❌ Failed to close ${ticket.identifier}:`, error.message);
      }
      await new Promise(resolve => setTimeout(resolve, 500));
    } else {
      stillOpen++;
    }
  }

  console.log(`\n📋 Auto-close summary:`);
  console.log(`   ✅ Closed: ${closed} resolved vulnerabilities`);
  console.log(`   🔓 Still open: ${stillOpen} active vulnerabilities`);
  if (noHash > 0) {
    console.log(`   ⏭️  Skipped: ${noHash} tickets without hash`);
  }
}

main().catch(error => {
  console.error('❌ Error:', error);
  process.exit(1);
});
