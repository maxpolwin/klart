#!/usr/bin/env node

/**
 * download-compressor-model.js
 *
 * Downloads the LLMLingua-2 MobileBERT ONNX prompt-compression model from
 * Hugging Face into models/compressor/<repo>/ so it can be loaded fully
 * offline by @atjsh/llmlingua-2 (via Transformers.js) at runtime.
 *
 * Usage: npm run download-compressor
 */

const https = require('https');
const fs = require('fs');
const path = require('path');

const REPO = 'atjsh/llmlingua-2-js-mobilebert-meetingbank';
const API_URL = `https://huggingface.co/api/models/${REPO}`;
const RESOLVE_BASE = `https://huggingface.co/${REPO}/resolve/main`;
const DEST_DIR = path.join(__dirname, '..', 'models', 'compressor', ...REPO.split('/'));

// Fallback file list if the HF API listing is unavailable. These are the files a
// Transformers.js token-classification model needs to load.
const FALLBACK_FILES = [
  'config.json',
  'tokenizer.json',
  'tokenizer_config.json',
  'special_tokens_map.json',
  'vocab.txt',
  'onnx/model.onnx',
];

// The onnx weights are the large file we verify; ~99MB for MobileBERT.
const ONNX_MIN_MB = 50;

function formatBytes(bytes) {
  if (!bytes || bytes === 0) return '0 Bytes';
  const k = 1024;
  const sizes = ['Bytes', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}

function httpGet(url, { json = false } = {}) {
  return new Promise((resolve, reject) => {
    const request = (currentUrl, redirects = 0) => {
      if (redirects > 5) return reject(new Error('Too many redirects'));
      https.get(currentUrl, { headers: { 'User-Agent': 'noschen-downloader' } }, (res) => {
        if (res.statusCode === 301 || res.statusCode === 302 || res.statusCode === 307 || res.statusCode === 308) {
          res.resume();
          const location = res.headers.location;
          if (!location) return reject(new Error(`Redirect (${res.statusCode}) with no Location header`));
          // Hugging Face redirects to relative paths (e.g. /api/resolve-cache/...);
          // resolve them against the current URL so https.get gets an absolute URL.
          const nextUrl = new URL(location, currentUrl).toString();
          return request(nextUrl, redirects + 1);
        }
        if (res.statusCode !== 200) {
          res.resume();
          return reject(new Error(`HTTP ${res.statusCode} for ${currentUrl}`));
        }
        if (json) {
          let body = '';
          res.on('data', (c) => (body += c));
          res.on('end', () => {
            try { resolve(JSON.parse(body)); } catch (e) { reject(e); }
          });
        } else {
          resolve(res);
        }
      }).on('error', reject);
    };
    request(url);
  });
}

function downloadTo(url, dest, showProgress) {
  return new Promise(async (resolve, reject) => {
    try {
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      const res = await httpGet(url);
      const total = parseInt(res.headers['content-length'], 10) || 0;
      const file = fs.createWriteStream(dest);
      let downloaded = 0;
      let lastPercent = 0;

      res.on('data', (chunk) => {
        downloaded += chunk.length;
        if (showProgress && total > 0) {
          const percent = Math.floor((downloaded / total) * 100);
          if (percent >= lastPercent + 5 || percent === 100) {
            lastPercent = percent;
            process.stdout.write(`\r  ${percent}% (${formatBytes(downloaded)} / ${formatBytes(total)})`);
          }
        }
      });

      res.pipe(file);
      file.on('finish', () => {
        file.close();
        if (showProgress) process.stdout.write('\n');
        resolve();
      });
      file.on('error', (err) => { fs.unlink(dest, () => {}); reject(err); });
    } catch (err) {
      reject(err);
    }
  });
}

async function getFileList() {
  try {
    const meta = await httpGet(API_URL, { json: true });
    const files = (meta.siblings || []).map((s) => s.rfilename).filter(Boolean);
    if (files.length > 0) return files;
  } catch (err) {
    console.warn(`Could not fetch file listing (${err.message}); using fallback list.`);
  }
  return FALLBACK_FILES;
}

function onnxLooksComplete() {
  const onnxPath = path.join(DEST_DIR, 'onnx', 'model.onnx');
  if (!fs.existsSync(onnxPath)) return false;
  const sizeMB = fs.statSync(onnxPath).size / (1024 * 1024);
  return sizeMB >= ONNX_MIN_MB;
}

async function main() {
  console.log('='.repeat(50));
  console.log('Noschen - LLMLingua-2 Compressor Model Download');
  console.log('='.repeat(50));
  console.log(`Repo: ${REPO}`);
  console.log(`Destination: ${DEST_DIR}`);
  console.log('');

  if (onnxLooksComplete() && fs.existsSync(path.join(DEST_DIR, 'config.json'))) {
    console.log('Compressor model already present. Delete the folder to re-download.');
    return;
  }

  const files = await getFileList();
  console.log(`Downloading ${files.length} files...`);
  console.log('');

  for (const rel of files) {
    const dest = path.join(DEST_DIR, rel);
    const url = `${RESOLVE_BASE}/${rel}`;
    const isBig = rel.endsWith('.onnx') || rel.endsWith('.onnx_data');
    process.stdout.write(`- ${rel}${isBig ? '' : ' ... '}`);
    try {
      await downloadTo(url, dest, isBig);
      if (!isBig) console.log('done');
    } catch (err) {
      // A missing optional file (e.g. tokenizer.json vs vocab.txt) is not fatal.
      console.log(`skipped (${err.message})`);
    }
  }

  console.log('');
  if (onnxLooksComplete()) {
    console.log('Compressor model downloaded successfully.');
    console.log('Prompt compression (LLMLingua-2) is now available in the app.');
  } else {
    console.error('Warning: onnx/model.onnx is missing or too small — download may be incomplete.');
    console.error(`You can manually download the model from: https://huggingface.co/${REPO}`);
    process.exit(1);
  }
}

main();
