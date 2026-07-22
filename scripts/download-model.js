#!/usr/bin/env node

const https = require('https');
const fs = require('fs');
const path = require('path');

const MODELS_DIR = path.join(__dirname, '..', 'models');
const REGISTRY_PATH = path.join(__dirname, '..', 'src', 'main', 'llm', 'modelRegistry.json');
const REGISTRY = JSON.parse(fs.readFileSync(REGISTRY_PATH, 'utf-8'));
const DEFAULT_MODEL_ID = 'qwen2.5-0.5b';

function parseModelArg() {
  const arg = process.argv.find((a) => a.startsWith('--model='));
  return arg ? arg.slice('--model='.length) : DEFAULT_MODEL_ID;
}

function getModelInfo(modelId) {
  const info = REGISTRY.find((m) => m.id === modelId);
  if (!info) {
    console.error(`Unknown model id: "${modelId}"`);
    console.error(`Available models: ${REGISTRY.map((m) => m.id).join(', ')}`);
    process.exit(1);
  }
  return info;
}

function formatBytes(bytes) {
  if (bytes === 0) return '0 Bytes';
  const k = 1024;
  const sizes = ['Bytes', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}

function downloadFile(url, dest, label) {
  return new Promise((resolve, reject) => {
    console.log(`Downloading ${label}...`);
    console.log(`URL: ${url}`);
    console.log(`Destination: ${dest}`);
    console.log('');

    if (!fs.existsSync(MODELS_DIR)) {
      fs.mkdirSync(MODELS_DIR, { recursive: true });
    }

    const file = fs.createWriteStream(dest);
    let downloadedBytes = 0;
    let totalBytes = 0;
    let lastPercent = 0;

    const request = (currentUrl) => {
      https.get(currentUrl, (response) => {
        // Handle redirects
        if (response.statusCode === 301 || response.statusCode === 302) {
          const redirectUrl = response.headers.location;
          console.log(`Following redirect to: ${redirectUrl}`);
          request(redirectUrl);
          return;
        }

        if (response.statusCode !== 200) {
          reject(new Error(`Failed to download: HTTP ${response.statusCode}`));
          return;
        }

        totalBytes = parseInt(response.headers['content-length'], 10) || 0;
        if (totalBytes > 0) {
          console.log(`File size: ${formatBytes(totalBytes)}`);
        }
        console.log('');

        response.on('data', (chunk) => {
          downloadedBytes += chunk.length;
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
          resolve();
        });

        file.on('error', (err) => {
          fs.unlink(dest, () => {}); // Delete incomplete file
          reject(err);
        });
      }).on('error', (err) => {
        fs.unlink(dest, () => {}); // Delete incomplete file
        reject(err);
      });
    };

    request(url);
  });
}

async function main() {
  const modelId = parseModelArg();
  const modelInfo = getModelInfo(modelId);
  const modelPath = path.join(MODELS_DIR, modelInfo.filename);
  const expectedSizeMB = modelInfo.approxDownloadSizeMB;

  console.log('='.repeat(50));
  console.log('Noschen - Model Download Script');
  console.log('='.repeat(50));
  console.log('');
  console.log(`Model: ${modelInfo.label} (${modelInfo.paramCount})`);
  console.log('');

  // Check if model already exists
  if (fs.existsSync(modelPath)) {
    const stats = fs.statSync(modelPath);
    const sizeMB = stats.size / (1024 * 1024);

    if (sizeMB > expectedSizeMB * 0.5) {
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
    await downloadFile(modelInfo.downloadUrl, modelPath, modelInfo.label);

    // Verify the download
    const stats = fs.statSync(modelPath);
    console.log(`Downloaded file size: ${formatBytes(stats.size)}`);

    if (stats.size < expectedSizeMB * 0.5 * 1024 * 1024) {
      console.warn('Warning: Downloaded file may be incomplete.');
    } else {
      console.log('');
      console.log(`${modelInfo.label} downloaded successfully!`);
      console.log('You can now run the app with: npm run dev');
    }
  } catch (error) {
    console.error('');
    console.error('Download failed:', error.message);
    console.error('');
    console.error('You can manually download the model from:');
    console.error(modelInfo.downloadUrl);
    console.error('');
    console.error(`And place it in: ${MODELS_DIR}`);
    process.exit(1);
  }
}

main();
