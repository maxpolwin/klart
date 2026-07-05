#!/usr/bin/env node

// Maintainer/CI convenience for pre-populating models/ before `npm run package`.
// End users download models from Settings → AI Provider inside the app.
//
// Usage: node scripts/download-model.js [--model=<id>]
//   (default model: qwen2.5-0.5b — preserves the original zero-arg behavior)

const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const registry = require('../src/main/llm/modelRegistry.json');

const MODELS_DIR = path.join(__dirname, '..', 'models');
const DEFAULT_MODEL_ID = 'qwen2.5-0.5b';

function parseModelArg() {
  const arg = process.argv.find((a) => a.startsWith('--model='));
  return arg ? arg.slice('--model='.length) : DEFAULT_MODEL_ID;
}

function formatBytes(bytes) {
  if (!bytes || bytes === 0) return '0 Bytes';
  const k = 1024;
  const sizes = ['Bytes', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}

function minValidSizeBytes(spec) {
  return spec.exactSizeBytes !== null
    ? Math.floor(spec.exactSizeBytes * 0.98)
    : Math.floor(spec.approxDownloadSizeMB * 0.9 * 1024 * 1024);
}

function downloadFile(spec, dest) {
  return new Promise((resolve, reject) => {
    console.log(`Downloading ${spec.label}...`);
    console.log(`URL: ${spec.downloadUrl}`);
    console.log(`Destination: ${dest}`);
    console.log('');

    if (!fs.existsSync(MODELS_DIR)) {
      fs.mkdirSync(MODELS_DIR, { recursive: true });
    }

    const file = fs.createWriteStream(dest);
    const hash = crypto.createHash('sha256');
    let downloadedBytes = 0;
    let totalBytes = 0;
    let lastPercent = 0;

    const fail = (err) => {
      file.close(() => fs.unlink(dest, () => {})); // Delete incomplete file
      reject(err);
    };

    const request = (currentUrl, redirects = 0) => {
      if (redirects > 5) return fail(new Error('Too many redirects'));
      https.get(currentUrl, { headers: { 'User-Agent': 'noschen-downloader', 'Accept-Encoding': 'identity' } }, (response) => {
        // Hugging Face redirects to the CDN, sometimes with relative Locations
        if ([301, 302, 307, 308].includes(response.statusCode)) {
          response.resume();
          const location = response.headers.location;
          if (!location) return fail(new Error(`Redirect (${response.statusCode}) with no Location header`));
          return request(new URL(location, currentUrl).toString(), redirects + 1);
        }

        if (response.statusCode !== 200) {
          response.resume();
          return fail(new Error(`Failed to download: HTTP ${response.statusCode}`));
        }

        totalBytes = parseInt(response.headers['content-length'], 10) || 0;
        if (totalBytes > 0) {
          console.log(`File size: ${formatBytes(totalBytes)}`);
        }
        console.log('');

        response.on('data', (chunk) => {
          downloadedBytes += chunk.length;
          hash.update(chunk);
          const percent = totalBytes > 0 ? Math.floor((downloadedBytes / totalBytes) * 100) : 0;

          // Update progress every 5%
          if (percent >= lastPercent + 5 || percent === 100) {
            lastPercent = percent;
            const progress = totalBytes > 0
              ? `${percent}% (${formatBytes(downloadedBytes)} / ${formatBytes(totalBytes)})`
              : formatBytes(downloadedBytes);
            process.stdout.write(`\rDownloading: ${progress}`);
          }
        });

        response.pipe(file);

        file.on('finish', () => {
          file.close();
          console.log('\n\nDownload complete!');
          resolve({ downloadedBytes, totalBytes, sha256: hash.digest('hex') });
        });

        file.on('error', fail);
      }).on('error', fail);
    };

    request(spec.downloadUrl);
  });
}

async function main() {
  console.log('='.repeat(50));
  console.log('Noschen - Model Download Script');
  console.log('='.repeat(50));
  console.log('');

  const modelId = parseModelArg();
  const spec = registry.models.find((m) => m.id === modelId);
  if (!spec) {
    console.error(`Unknown model id: ${modelId}`);
    console.error(`Available models: ${registry.models.map((m) => m.id).join(', ')}`);
    process.exit(1);
  }

  const modelPath = path.join(MODELS_DIR, spec.filename);

  // Check if model already exists
  if (fs.existsSync(modelPath)) {
    const stats = fs.statSync(modelPath);

    if (stats.size >= minValidSizeBytes(spec)) {
      console.log(`Model already exists: ${modelPath}`);
      console.log(`Size: ${formatBytes(stats.size)}`);
      console.log('');
      console.log('To re-download, delete the file and run this script again.');
      return;
    } else {
      console.log('Existing model file appears incomplete. Re-downloading...');
      fs.unlinkSync(modelPath);
    }
  }

  try {
    const result = await downloadFile(spec, modelPath);

    const stats = fs.statSync(modelPath);
    console.log(`Downloaded file size: ${formatBytes(stats.size)}`);

    if (spec.exactSizeBytes !== null && stats.size !== spec.exactSizeBytes) {
      console.error(`Size mismatch: expected ${spec.exactSizeBytes} bytes. Deleting corrupt file.`);
      fs.unlinkSync(modelPath);
      process.exit(1);
    }
    if (spec.sha256 && result.sha256 !== spec.sha256.toLowerCase()) {
      console.error('Checksum mismatch — download corrupted. Deleting file.');
      fs.unlinkSync(modelPath);
      process.exit(1);
    }
    if (stats.size < minValidSizeBytes(spec)) {
      console.warn('Warning: Downloaded file may be incomplete.');
    } else {
      console.log('');
      console.log(`Model downloaded successfully! (sha256: ${result.sha256})`);
      console.log('You can now run the app with: npm run dev');
    }
  } catch (error) {
    console.error('');
    console.error('Download failed:', error.message);
    console.error('');
    console.error('You can manually download the model from:');
    console.error(spec.downloadUrl);
    console.error('');
    console.error(`And place it in: ${MODELS_DIR}`);
    process.exit(1);
  }
}

main();
