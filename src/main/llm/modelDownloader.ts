import * as path from 'path';
import * as fs from 'fs';
import * as fsp from 'fs/promises';
import * as crypto from 'crypto';
import { Readable, Transform } from 'stream';
import { pipeline } from 'stream/promises';
import {
  BuiltinModelSpec,
  BUILTIN_MODELS,
  expectedSizeBytes,
  getModelById,
} from './modelRegistry';
import { getUserModelsDir, getModelPath, disposeIfCurrentModel } from './localLLM';

export interface DownloadProgress {
  modelId: string;
  downloadedBytes: number;
  totalBytes: number;
}

type ProgressSink = (progress: DownloadProgress) => void;

interface DownloadState {
  downloadedBytes: number;
  totalBytes: number;
  abort: AbortController;
  cancelled: boolean;
  promise: Promise<{ success: boolean; error?: string }>;
}

const inFlight = new Map<string, DownloadState>();

const STALL_TIMEOUT_MS = 60_000;      // abort if no bytes arrive for this long
const STALL_CHECK_INTERVAL_MS = 10_000;
const PROGRESS_THROTTLE_MS = 500;
const DISK_SPACE_MARGIN = 1.05;       // require 5% headroom over the remaining bytes

function partialPathFor(spec: BuiltinModelSpec): string {
  return path.join(getUserModelsDir(), `${spec.filename}.partial`);
}

function finalPathFor(spec: BuiltinModelSpec): string {
  return path.join(getUserModelsDir(), spec.filename);
}

export function getDownloadSnapshot(modelId: string): DownloadProgress | null {
  const state = inFlight.get(modelId);
  if (!state) return null;
  return { modelId, downloadedBytes: state.downloadedBytes, totalBytes: state.totalBytes };
}

export function cancelDownload(modelId: string): boolean {
  const state = inFlight.get(modelId);
  if (!state) return false;
  state.cancelled = true;
  state.abort.abort(new Error('Download cancelled'));
  return true;
}

// Abort all in-flight downloads and wait for their streams to close cleanly.
// Called on app quit: an unflushed write stream can leave torn tail bytes on
// the .partial file, which the resume path cannot detect until the final
// hash check (wasting a full re-download).
export async function abortAllDownloads(): Promise<void> {
  const pending = [...inFlight.values()];
  for (const state of pending) {
    state.cancelled = true;
    state.abort.abort(new Error('App is quitting'));
  }
  await Promise.allSettled(pending.map((s) => s.promise));
}

// Remove orphaned .partial files (no download in flight and the final file
// already exists — e.g. a crash landed between rename and cleanup).
export async function sweepStalePartials(): Promise<void> {
  try {
    const dir = getUserModelsDir();
    if (!fs.existsSync(dir)) return;
    for (const spec of BUILTIN_MODELS) {
      const partial = partialPathFor(spec);
      if (!inFlight.has(spec.id) && fs.existsSync(partial) && fs.existsSync(finalPathFor(spec))) {
        await fsp.unlink(partial);
        console.log(`[ModelDownloader] Removed orphaned partial: ${partial}`);
      }
    }
  } catch (e) {
    console.warn('[ModelDownloader] Partial sweep failed:', e);
  }
}

// Delete a model file downloaded into userData (bundled/dev copies are not
// touched). Disposes the model first if it is currently loaded.
export async function deleteDownloadedModel(modelId: string): Promise<{ success: boolean; error?: string }> {
  const spec = getModelById(modelId);
  if (!spec) return { success: false, error: `Unknown model: ${modelId}` };
  if (inFlight.has(modelId)) {
    return { success: false, error: 'A download for this model is in progress. Cancel it first.' };
  }

  try {
    await disposeIfCurrentModel(modelId);
    let removed = false;
    for (const file of [finalPathFor(spec), partialPathFor(spec)]) {
      if (fs.existsSync(file)) {
        await fsp.unlink(file);
        removed = true;
      }
    }
    return removed ? { success: true } : { success: false, error: 'No downloaded copy of this model to delete.' };
  } catch (error) {
    return { success: false, error: error instanceof Error ? error.message : 'Delete failed' };
  }
}

async function hashExistingPartial(partialPath: string): Promise<crypto.Hash> {
  const hash = crypto.createHash('sha256');
  await pipeline(
    fs.createReadStream(partialPath),
    new Transform({
      transform(chunk, _enc, callback) {
        hash.update(chunk);
        callback();
      },
    })
  );
  return hash;
}

async function checkDiskSpace(dir: string, neededBytes: number): Promise<string | null> {
  try {
    const stats = await fsp.statfs(dir);
    const available = Number(stats.bavail) * Number(stats.bsize);
    if (available < neededBytes * DISK_SPACE_MARGIN) {
      const neededGB = (neededBytes / 1024 ** 3).toFixed(1);
      const availableGB = (available / 1024 ** 3).toFixed(1);
      return `Not enough disk space: need ~${neededGB}GB, ${availableGB}GB available.`;
    }
  } catch (e) {
    // statfs failing is not a reason to block the download
    console.warn('[ModelDownloader] Disk space check failed:', e);
  }
  return null;
}

export function downloadModel(
  modelId: string,
  onProgress: ProgressSink
): Promise<{ success: boolean; error?: string }> {
  const spec = getModelById(modelId);
  if (!spec) {
    return Promise.resolve({ success: false, error: `Unknown model: ${modelId}` });
  }
  if (inFlight.has(modelId)) {
    return Promise.resolve({ success: false, error: 'Download already in progress' });
  }

  const abort = new AbortController();
  const state: DownloadState = {
    downloadedBytes: 0,
    totalBytes: expectedSizeBytes(spec),
    abort,
    cancelled: false,
    promise: Promise.resolve({ success: false }),
  };
  state.promise = runDownload(spec, state, onProgress).finally(() => {
    inFlight.delete(modelId);
  });
  inFlight.set(modelId, state);
  return state.promise;
}

async function runDownload(
  spec: BuiltinModelSpec,
  state: DownloadState,
  onProgress: ProgressSink
): Promise<{ success: boolean; error?: string }> {
  const dir = getUserModelsDir();
  const partialPath = partialPathFor(spec);
  const finalPath = finalPathFor(spec);

  let stallTimer: ReturnType<typeof setInterval> | null = null;

  try {
    await fsp.mkdir(dir, { recursive: true });

    // Already installed anywhere (dev dir / userData / bundled resources)?
    if (fs.existsSync(getModelPath(spec.id))) {
      return { success: true };
    }

    // Resume support: hash the existing partial bytes so the final digest
    // covers the whole file, then ask the server for the remainder.
    let resumeFrom = 0;
    let hash = crypto.createHash('sha256');
    if (fs.existsSync(partialPath)) {
      resumeFrom = (await fsp.stat(partialPath)).size;
      if (resumeFrom > 0) {
        console.log(`[ModelDownloader] Resuming ${spec.id} from ${resumeFrom} bytes`);
        hash = await hashExistingPartial(partialPath);
      }
    }

    const diskError = await checkDiskSpace(dir, expectedSizeBytes(spec) - resumeFrom);
    if (diskError) {
      return { success: false, error: diskError };
    }

    // Accept-Encoding: identity — transparent gzip/br decompression would
    // corrupt Range offsets and byte-count verification.
    const headers: Record<string, string> = { 'accept-encoding': 'identity' };
    if (resumeFrom > 0) {
      headers.range = `bytes=${resumeFrom}-`;
    }

    // Always fetch the original registry URL: it redirects to a signed CDN
    // URL that expires, so a stored redirect target cannot be reused.
    const response = await fetch(spec.downloadUrl, { headers, signal: state.abort.signal });

    if (response.status === 416) {
      // Range not satisfiable: the partial already holds the whole file
      // (a previous run crashed between the last byte and the rename).
      // No server-reported total here — verify size only if pinned.
      return await verifyAndCommit(spec, partialPath, finalPath, hash, resumeFrom, 0);
    }

    if (resumeFrom > 0 && response.status === 200) {
      // Server ignored the Range header: restart from zero.
      console.log('[ModelDownloader] Server ignored Range request, restarting from zero');
      resumeFrom = 0;
      hash = crypto.createHash('sha256');
      await fsp.rm(partialPath, { force: true });
    } else if (!response.ok && response.status !== 206) {
      return { success: false, error: `Download failed: HTTP ${response.status}` };
    }

    const contentLength = Number(response.headers.get('content-length')) || 0;
    // The verifiable total exists only when the server reported one; the
    // registry's approximate size is for progress display, never verification.
    const verifiableTotal = contentLength > 0 ? resumeFrom + contentLength : 0;
    const totalBytes = verifiableTotal || expectedSizeBytes(spec);
    state.totalBytes = totalBytes;
    state.downloadedBytes = resumeFrom;

    if (!response.body) {
      return { success: false, error: 'Download failed: empty response body' };
    }

    // Stall detection: a dead connection can otherwise hang the stream forever.
    let lastDataAt = Date.now();
    stallTimer = setInterval(() => {
      if (Date.now() - lastDataAt > STALL_TIMEOUT_MS) {
        state.abort.abort(new Error('Download stalled (no data for 60s)'));
      }
    }, STALL_CHECK_INTERVAL_MS);

    let lastProgressAt = 0;
    const counter = new Transform({
      transform(chunk: Buffer, _enc, callback) {
        lastDataAt = Date.now();
        state.downloadedBytes += chunk.length;
        hash.update(chunk);
        const now = Date.now();
        if (now - lastProgressAt >= PROGRESS_THROTTLE_MS || state.downloadedBytes === totalBytes) {
          lastProgressAt = now;
          onProgress({ modelId: spec.id, downloadedBytes: state.downloadedBytes, totalBytes });
        }
        callback(null, chunk);
      },
    });

    await pipeline(
      Readable.fromWeb(response.body as any),
      counter,
      fs.createWriteStream(partialPath, { flags: resumeFrom > 0 ? 'a' : 'w' }),
      { signal: state.abort.signal }
    );

    return await verifyAndCommit(spec, partialPath, finalPath, hash, state.downloadedBytes, verifiableTotal);
  } catch (error) {
    if (state.cancelled) {
      // Keep the .partial file: the next attempt resumes from it.
      return { success: false, error: 'Download cancelled' };
    }
    const message = error instanceof Error ? error.message : 'Download failed';
    console.error(`[ModelDownloader] Download of ${spec.id} failed:`, message);
    // Network errors also keep the partial for resume.
    return { success: false, error: message };
  } finally {
    if (stallTimer) clearInterval(stallTimer);
  }
}

async function verifyAndCommit(
  spec: BuiltinModelSpec,
  partialPath: string,
  finalPath: string,
  hash: crypto.Hash,
  downloadedBytes: number,
  serverTotalBytes: number
): Promise<{ success: boolean; error?: string }> {
  const actualSize = (await fsp.stat(partialPath)).size;

  // Size check: against the pinned exact size when available, otherwise
  // against what the server said it would send (0 = no verifiable total).
  const expected = spec.exactSizeBytes ?? serverTotalBytes;
  if (spec.exactSizeBytes === null && serverTotalBytes === 0) {
    console.warn(`[ModelDownloader] No pinned or server-reported size for ${spec.id}; skipping size verification`);
  }
  if (expected > 0 && actualSize !== expected) {
    await fsp.rm(partialPath, { force: true });
    return {
      success: false,
      error: `Downloaded file is ${actualSize} bytes, expected ${expected}. The file was removed — please try again.`,
    };
  }

  if (spec.sha256) {
    const digest = hash.digest('hex');
    if (digest !== spec.sha256.toLowerCase()) {
      await fsp.rm(partialPath, { force: true });
      return {
        success: false,
        error: 'Checksum verification failed — the download was corrupted or tampered with. The file was removed.',
      };
    }
  }

  // Atomic commit: the final filename only ever holds a fully verified file.
  await fsp.rename(partialPath, finalPath);
  console.log(`[ModelDownloader] ${spec.id} downloaded and verified (${downloadedBytes} bytes)`);
  return { success: true };
}
