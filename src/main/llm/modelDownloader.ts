import * as fs from 'fs';
import * as path from 'path';
import {
  BuiltinModelId,
  getBuiltinModelInfo,
  getBuiltinModelDownloadTarget,
} from './localLLM';

export interface DownloadProgress {
  modelId: BuiltinModelId;
  percent: number;
  downloadedMB: number;
  totalMB: number;
}

const inFlightDownloads = new Set<BuiltinModelId>();

export function isDownloadInProgress(modelId: BuiltinModelId): boolean {
  return inFlightDownloads.has(modelId);
}

// Downloads a builtin model's GGUF file into the app's userData/models
// directory (always writable, dev or packaged alike), reporting throttled
// progress. Generic over modelId - covers re-downloading a missing/corrupted
// Qwen file just as much as fetching Phi-3-mini for the first time.
export async function downloadBuiltinModel(
  modelId: BuiltinModelId,
  onProgress?: (progress: DownloadProgress) => void
): Promise<{ success: boolean; error?: string }> {
  if (inFlightDownloads.has(modelId)) {
    return { success: false, error: 'A download for this model is already in progress.' };
  }

  const info = getBuiltinModelInfo(modelId);
  const destPath = getBuiltinModelDownloadTarget(modelId);
  const destDir = path.dirname(destPath);

  inFlightDownloads.add(modelId);

  try {
    if (!fs.existsSync(destDir)) {
      fs.mkdirSync(destDir, { recursive: true });
    }

    const response = await fetch(info.downloadUrl);
    if (!response.ok || !response.body) {
      return { success: false, error: `Failed to download ${info.label}: HTTP ${response.status}` };
    }

    const totalBytes = parseInt(response.headers.get('content-length') || '0', 10);
    let downloadedBytes = 0;
    let lastReportedPercent = -1;

    const fileStream = fs.createWriteStream(destPath);
    const reader = response.body.getReader();

    try {
      // eslint-disable-next-line no-constant-condition
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        downloadedBytes += value.byteLength;
        fileStream.write(Buffer.from(value));

        if (totalBytes > 0 && onProgress) {
          const percent = Math.floor((downloadedBytes / totalBytes) * 100);
          if (percent >= lastReportedPercent + 5 || percent === 100) {
            lastReportedPercent = percent;
            onProgress({
              modelId,
              percent,
              downloadedMB: downloadedBytes / (1024 * 1024),
              totalMB: totalBytes / (1024 * 1024),
            });
          }
        }
      }
    } finally {
      await new Promise<void>((resolve, reject) => {
        fileStream.end((err?: Error | null) => (err ? reject(err) : resolve()));
      });
    }

    // Verify the download actually completed - a truncated multi-GB file
    // could still exceed a flat byte-count threshold while being unusable.
    const stats = fs.statSync(destPath);
    const sizeMB = stats.size / (1024 * 1024);
    if (sizeMB < info.approxDownloadSizeMB * 0.5) {
      fs.unlinkSync(destPath);
      return { success: false, error: `Download of ${info.label} appears incomplete. Please try again.` };
    }

    return { success: true };
  } catch (error) {
    try {
      if (fs.existsSync(destPath)) fs.unlinkSync(destPath);
    } catch {
      // Ignore cleanup failure
    }
    const errorMessage = error instanceof Error ? error.message : 'Download failed';
    return { success: false, error: errorMessage };
  } finally {
    inFlightDownloads.delete(modelId);
  }
}
