import * as os from 'os';
import * as registryJson from './modelRegistry.json';

// Mirrors the shape in src/main/llm/modelRegistry.json. The renderer gets the
// same data via the typed re-export in src/shared/types.ts (tsconfig.main's
// rootDir prevents the main process from importing src/shared directly).
export interface BuiltinModelSpec {
  id: string;
  label: string;
  paramCount: string;
  filename: string;
  downloadUrl: string;
  approxDownloadSizeMB: number;
  exactSizeBytes: number | null;
  sha256: string | null;
  nativeMaxContext: number;
  uiMaxContext: number;
  recommendedContextSize: number;
  recommendedMaxTokens: number;
  recommendedBatchSize: number;
  kvBytesPerToken: number;
  contentBudgetTokens: number;
  description: string;
}

export const BUILTIN_MODELS: BuiltinModelSpec[] = registryJson.models;

export const DEFAULT_BUILTIN_MODEL_ID = 'qwen2.5-0.5b';

export function getModelById(modelId: string | undefined | null): BuiltinModelSpec | undefined {
  return BUILTIN_MODELS.find((m) => m.id === modelId);
}

export function resolveModel(modelId: string | undefined | null): BuiltinModelSpec {
  return getModelById(modelId) ?? getModelById(DEFAULT_BUILTIN_MODEL_ID)!;
}

export function expectedSizeBytes(spec: BuiltinModelSpec): number {
  return spec.exactSizeBytes ?? spec.approxDownloadSizeMB * 1024 * 1024;
}

// Minimum plausible size for an intact model file: exact size (with a small
// tolerance) when pinned, otherwise 90% of the documented approximate size.
export function minValidSizeBytes(spec: BuiltinModelSpec): number {
  return spec.exactSizeBytes !== null
    ? Math.floor(spec.exactSizeBytes * 0.98)
    : Math.floor(spec.approxDownloadSizeMB * 0.9 * 1024 * 1024);
}

// RAM-aware context ceiling: how large a KV cache this machine can plausibly
// hold for the given model. Budget is half of total RAM (leaves room for the
// OS, Electron, and the app itself) minus the resident model weights; the
// result is floored to the 256-token alignment llama.cpp uses and clamped to
// [2048, uiMaxContext]. This caps the Settings UI; the runtime independently
// clamps again at context creation via contextSize: { max } in localLLM.ts.
export function effectiveMaxContext(spec: BuiltinModelSpec): number {
  const kvBudgetBytes = os.totalmem() * 0.5 - expectedSizeBytes(spec);
  const fitTokens = Math.floor(kvBudgetBytes / spec.kvBytesPerToken / 256) * 256;
  return Math.min(spec.uiMaxContext, Math.max(2048, fitTokens));
}
