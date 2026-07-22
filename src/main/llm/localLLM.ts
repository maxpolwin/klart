import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';
import { app } from 'electron';
import modelRegistryData from './modelRegistry.json';

export interface BuiltinModelInfo {
  id: string;
  label: string;
  paramCount: string;
  filename: string;
  downloadUrl: string;
  approxDownloadSizeMB: number;
  nativeMaxContext: number;
  uiMaxContext: number;
  recommendedContextSize: number;
  recommendedMaxTokens: number;
  recommendedBatchSize: number;
  description: string;
}

const MODEL_REGISTRY = modelRegistryData as BuiltinModelInfo[];

export type BuiltinModelId = 'qwen2.5-0.5b' | 'phi-3-mini-128k';
export const DEFAULT_BUILTIN_MODEL_ID: BuiltinModelId = 'qwen2.5-0.5b';

export function getBuiltinModelInfo(modelId: BuiltinModelId): BuiltinModelInfo {
  const info = MODEL_REGISTRY.find((m) => m.id === modelId);
  if (!info) {
    throw new Error(`Unknown builtin model: ${modelId}`);
  }
  return info;
}

export function listBuiltinModels(): BuiltinModelInfo[] {
  return MODEL_REGISTRY;
}

// Force real ESM dynamic import (bypasses TypeScript's CommonJS transformation)
// This is necessary because node-llama-cpp v3.x is ESM-only with top-level await
const dynamicImport = new Function('specifier', 'return import(specifier)') as (specifier: string) => Promise<any>;

// State management
let llamaModule: any = null;
let llama: any = null;
let model: any = null;
let isInitialized = false;
let isInitializing = false;
let initError: string | null = null;
let lastInitAttempt = 0;
let asarResolutionPatched = false;
let currentModelId: BuiltinModelId | null = null;

// Get the correct import path for node-llama-cpp.
// In packaged mode, we must import from the unpacked directory because
// node-llama-cpp is ESM-only with native binaries that need real filesystem paths.
function getNodeLlamaCppImportPath(): string {
  if (!app.isPackaged) {
    return 'node-llama-cpp';
  }
  const unpackedPath = path.join(
    process.resourcesPath,
    'app.asar.unpacked', 'node_modules', 'node-llama-cpp', 'dist', 'index.js'
  );
  return `file://${unpackedPath}`;
}

// Ensure that hoisted dependencies inside app.asar can be resolved when
// node-llama-cpp is loaded from app.asar.unpacked.
//
// Problem: node-llama-cpp is unpacked from the asar for native binary support,
// but its hoisted JS dependencies (universalify, graceful-fs, jsonfile, etc.)
// remain inside app.asar. Node's module resolution from the unpacked directory
// walks the real filesystem and never finds these modules.
//
// Solution: Add app.asar/node_modules to Node's global module search paths.
// This array is checked as a last-resort fallback after normal node_modules
// traversal fails. Electron's fs patches transparently read from asar archives,
// so modules resolved through this path load correctly.
function ensureAsarModuleResolution(): void {
  if (!app.isPackaged || asarResolutionPatched) return;
  asarResolutionPatched = true;

  const Module = require('module');
  const asarNodeModules = path.join(process.resourcesPath, 'app.asar', 'node_modules');
  if (!Module.globalPaths.includes(asarNodeModules)) {
    Module.globalPaths.push(asarNodeModules);
  }
}

// Detect Apple Silicon for Metal acceleration
function isAppleSilicon(): boolean {
  return process.platform === 'darwin' && os.arch() === 'arm64';
}

// Get GPU layers policy for the platform.
// "max" lets node-llama-cpp auto-fit as many layers as fit in available
// VRAM/unified memory for whichever model is loaded, rather than a number
// hand-tuned for one specific model's size.
function getOptimalGpuLayers(): number | 'max' {
  if (isAppleSilicon()) {
    return 'max'; // Metal acceleration on Apple Silicon
  }
  // CPU-only for other platforms (or set to positive number for CUDA/ROCm)
  return 0;
}

// LLM configuration interface
export interface LLMConfig {
  contextSize: number;
  maxTokens: number;
  batchSize: number;
  modelId?: BuiltinModelId;
}

// Default configuration for small models
const DEFAULT_CONFIG: LLMConfig = {
  contextSize: 2048,
  maxTokens: 1536,  // Increased for detailed responses
  batchSize: 512,
  modelId: DEFAULT_BUILTIN_MODEL_ID,
};

// Static config (not user-configurable)
const STATIC_CONFIG = {
  temperature: 0.7,
  gpuLayers: getOptimalGpuLayers(),
};

// Retry configuration
const INIT_RETRY_DELAY = 5000; // 5 seconds between retry attempts

function getUserDataModelsDir(): string {
  return path.join(app.getPath('userData'), 'models');
}

// Where an in-app download for this model should be written. Always a
// writable location regardless of dev vs. packaged.
export function getBuiltinModelDownloadTarget(modelId: BuiltinModelId): string {
  const { filename } = getBuiltinModelInfo(modelId);
  return path.join(getUserDataModelsDir(), filename);
}

// Resolve an existing model file across all the places it could live:
// the dev-mode models/ dir, the packaged app's bundled resources, or
// wherever the in-app downloader wrote it (userData). Falls back to the
// userData download target if the file isn't found anywhere yet.
function getModelPath(modelId: BuiltinModelId): string {
  const { filename } = getBuiltinModelInfo(modelId);
  const candidateDirs = [
    app.isPackaged
      ? path.join(process.resourcesPath, 'models')
      : path.join(process.cwd(), 'models'),
    getUserDataModelsDir(),
  ];

  for (const dir of candidateDirs) {
    const candidate = path.join(dir, filename);
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  return getBuiltinModelDownloadTarget(modelId);
}

export async function checkLocalLLMAvailable(
  modelId: BuiltinModelId = DEFAULT_BUILTIN_MODEL_ID
): Promise<{ available: boolean; error?: string }> {
  const modelPath = getModelPath(modelId);
  const { approxDownloadSizeMB, label } = getBuiltinModelInfo(modelId);

  if (!fs.existsSync(modelPath)) {
    return {
      available: false,
      error: `${label} model file not found. Download it from Settings → AI Provider, or place it manually at: ${modelPath}`,
    };
  }

  const stats = fs.statSync(modelPath);
  const sizeMB = stats.size / (1024 * 1024);

  if (sizeMB < approxDownloadSizeMB * 0.5) {
    return {
      available: false,
      error: `${label} model file appears corrupted or incomplete. Re-download it from Settings → AI Provider.`,
    };
  }

  return { available: true };
}

export async function initializeLocalLLM(
  modelId: BuiltinModelId = DEFAULT_BUILTIN_MODEL_ID
): Promise<{ success: boolean; error?: string }> {
  // Prevent concurrent initialization
  if (isInitializing) {
    return { success: false, error: 'Initialization already in progress' };
  }

  // Return cached result if recently attempted (only applies to the same model;
  // a switch to a different model should always get a fresh attempt)
  if (initError && currentModelId === modelId && Date.now() - lastInitAttempt < INIT_RETRY_DELAY) {
    return { success: false, error: initError };
  }

  // Already initialized with the requested model
  if (isInitialized && model && currentModelId === modelId) {
    return { success: true };
  }

  // Switching models: dispose the previously loaded one before loading the new one
  if (isInitialized && model && currentModelId !== modelId) {
    console.log(`[LocalLLM] Switching model (${currentModelId} -> ${modelId}), disposing previous...`);
    await disposeLocalLLM();
  }

  isInitializing = true;
  lastInitAttempt = Date.now();

  try {
    // Check model availability first
    const availability = await checkLocalLLMAvailable(modelId);
    if (!availability.available) {
      throw new Error(availability.error);
    }

    const modelPath = getModelPath(modelId);
    console.log('[LocalLLM] Initializing with model:', modelPath);

    // Dynamic import for ESM module (using dynamicImport to bypass CommonJS transformation)
    if (!llamaModule) {
      ensureAsarModuleResolution();
      const importPath = getNodeLlamaCppImportPath();
      console.log('[LocalLLM] Loading node-llama-cpp module from:', importPath);
      llamaModule = await dynamicImport(importPath);
    }

    const { getLlama } = llamaModule;

    // Initialize llama runtime
    if (!llama) {
      console.log('[LocalLLM] Initializing llama runtime...');
      llama = await getLlama();
    }

    // Load model with GPU acceleration where available
    const gpuLayers = STATIC_CONFIG.gpuLayers;
    console.log(`[LocalLLM] Loading model with gpuLayers=${gpuLayers} (Metal: ${isAppleSilicon()})...`);
    model = await llama.loadModel({
      modelPath,
      gpuLayers, // "max" auto-fits to available VRAM/unified memory on Apple Silicon, 0 (CPU) elsewhere
    });

    // Note: Context is created fresh for each generation to avoid sequence exhaustion
    isInitialized = true;
    currentModelId = modelId;
    initError = null;
    console.log('[LocalLLM] Initialization complete');

    return { success: true };
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown initialization error';
    console.error('[LocalLLM] Initialization failed:', errorMessage);
    initError = errorMessage;
    isInitialized = false;

    // Clean up partial state
    await disposeLocalLLM();

    return { success: false, error: errorMessage };
  } finally {
    isInitializing = false;
  }
}

export async function generateLocalResponse(
  systemPrompt: string,
  userPrompt: string,
  config?: Partial<LLMConfig>
): Promise<{ response?: string; error?: string }> {
  // Merge provided config with defaults
  const llmConfig = { ...DEFAULT_CONFIG, ...config };
  const modelId = llmConfig.modelId ?? DEFAULT_BUILTIN_MODEL_ID;

  // Ensure initialized with the requested model
  if (!isInitialized || !model || currentModelId !== modelId) {
    const initResult = await initializeLocalLLM(modelId);
    if (!initResult.success) {
      return { error: initResult.error };
    }
  }

  let localContext: any = null;
  let session: any = null;

  try {
    const { LlamaChatSession } = llamaModule;

    // Create a fresh context for each request to avoid sequence exhaustion
    console.log(`[LocalLLM] Creating context (size: ${llmConfig.contextSize}, maxTokens: ${llmConfig.maxTokens}, batchSize: ${llmConfig.batchSize})...`);
    localContext = await model.createContext({
      contextSize: llmConfig.contextSize,
      batchSize: llmConfig.batchSize,
    });

    // Get a sequence from the fresh context
    const contextSequence = localContext.getSequence();

    // Create a session for this request
    session = new LlamaChatSession({
      contextSequence,
      systemPrompt: systemPrompt,
    });

    console.log('[LocalLLM] Generating response...');
    const startTime = Date.now();

    const response = await session.prompt(userPrompt, {
      maxTokens: llmConfig.maxTokens,
      temperature: STATIC_CONFIG.temperature,
    });

    const duration = Date.now() - startTime;
    console.log(`[LocalLLM] Response generated in ${duration}ms`);

    return { response };
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Generation failed';
    console.error('[LocalLLM] Generation error:', errorMessage);
    return { error: errorMessage };
  } finally {
    // Dispose of session and context to free resources
    try {
      if (session) {
        await session.dispose?.();
      }
    } catch (e) {
      // Ignore
    }
    try {
      if (localContext) {
        await localContext.dispose?.();
      }
    } catch (e) {
      // Ignore
    }
  }
}

export async function disposeLocalLLM(): Promise<void> {
  console.log('[LocalLLM] Disposing...');

  try {
    if (model) {
      await model.dispose();
    }
  } catch (e) {
    console.error('[LocalLLM] Error disposing model:', e);
  }

  model = null;
  isInitialized = false;
  currentModelId = null;
  console.log('[LocalLLM] Disposed');
}

export function getLocalLLMStatus(): {
  initialized: boolean;
  initializing: boolean;
  error: string | null;
  modelId: BuiltinModelId | null;
  gpuAcceleration: {
    enabled: boolean;
    type: string;
    layers: number | string;
  };
} {
  const gpuEnabled = STATIC_CONFIG.gpuLayers !== 0;
  return {
    initialized: isInitialized,
    initializing: isInitializing,
    error: initError,
    modelId: currentModelId,
    gpuAcceleration: {
      enabled: gpuEnabled,
      type: isAppleSilicon() ? 'Metal (Apple Silicon)' : (gpuEnabled ? 'GPU' : 'CPU'),
      layers: STATIC_CONFIG.gpuLayers,
    },
  };
}

// Utility: Estimate token count (rough approximation)
export function estimateTokens(text: string): number {
  // Rough estimate: ~4 characters per token for English
  return Math.ceil(text.length / 4);
}

// Utility: Truncate text to fit within token budget
export function truncateToTokenBudget(text: string, maxTokens: number): string {
  const estimatedTokens = estimateTokens(text);
  if (estimatedTokens <= maxTokens) {
    return text;
  }

  // Truncate proportionally
  const ratio = maxTokens / estimatedTokens;
  const targetLength = Math.floor(text.length * ratio * 0.9); // 10% safety margin
  return text.substring(0, targetLength) + '...';
}
