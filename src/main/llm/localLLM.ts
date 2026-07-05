import * as path from 'path';
import * as fs from 'fs';
import { app } from 'electron';
import {
  BuiltinModelSpec,
  DEFAULT_BUILTIN_MODEL_ID,
  minValidSizeBytes,
  resolveModel,
} from './modelRegistry';

// Force real ESM dynamic import (bypasses TypeScript's CommonJS transformation)
// This is necessary because node-llama-cpp v3.x is ESM-only with top-level await
const dynamicImport = new Function('specifier', 'return import(specifier)') as (specifier: string) => Promise<any>;

// State management
let llamaModule: any = null;
let llama: any = null;
let model: any = null;
let currentModelId: string | null = null;
let isInitialized = false;
let initPromise: Promise<{ success: boolean; error?: string }> | null = null;
let initError: string | null = null;
let initErrorModelId: string | null = null;
let lastInitAttempt = 0;
let asarResolutionPatched = false;

// In-flight generation tracking: the model must never be disposed while a
// native prompt() call is running (that is a hard crash, not an exception).
let activeGenerations = 0;
const activeGenerationAborts = new Set<AbortController>();
let lastResolvedContextSize: number | null = null;

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

// LLM configuration interface
export interface LLMConfig {
  contextSize: number;
  maxTokens: number;
  batchSize: number;
  modelId?: string;
}

// Default configuration for small models
const DEFAULT_CONFIG: LLMConfig = {
  contextSize: 2048,
  maxTokens: 1536,  // Increased for detailed responses
  batchSize: 512,
};

// Static config (not user-configurable)
const STATIC_CONFIG = {
  temperature: 0.7,
};

// Retry configuration
const INIT_RETRY_DELAY = 5000; // 5 seconds between retry attempts
const MODEL_SWITCH_DRAIN_MS = 15000;   // wait this long for generations to finish...
const MODEL_SWITCH_SETTLE_MS = 10000;  // ...then abort them and wait this long to settle

export function getUserModelsDir(): string {
  return path.join(app.getPath('userData'), 'models');
}

// Resolve where a model file lives (or where a download should put it).
// Order: dev models/ dir, then userData (in-app downloads — a user-fetched
// copy wins over a bundled one), then packaged resources.
export function getModelPath(modelId?: string): string {
  const spec = resolveModel(modelId);
  const candidates = [
    ...(app.isPackaged ? [] : [path.join(process.cwd(), 'models', spec.filename)]),
    path.join(getUserModelsDir(), spec.filename),
    ...(app.isPackaged ? [path.join(process.resourcesPath, 'models', spec.filename)] : []),
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  // Nothing on disk: return the (always-writable) download target.
  return path.join(getUserModelsDir(), spec.filename);
}

export async function checkLocalLLMAvailable(modelId?: string): Promise<{ available: boolean; error?: string }> {
  const spec = resolveModel(modelId);
  const modelPath = getModelPath(spec.id);

  if (!fs.existsSync(modelPath)) {
    return {
      available: false,
      error: `Model file not found: ${modelPath}. Download it from Settings → AI Provider.`,
    };
  }

  const stats = fs.statSync(modelPath);
  if (stats.size < minValidSizeBytes(spec)) {
    return {
      available: false,
      error: `Model file appears corrupted (${Math.round(stats.size / (1024 * 1024))}MB, expected ~${spec.approxDownloadSizeMB}MB). Re-download it from Settings → AI Provider.`,
    };
  }

  return { available: true };
}

async function waitForGenerationsToDrain(timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (activeGenerations > 0 && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return activeGenerations === 0;
}

// Drain in-flight generations before a dispose/switch. Never tears the model
// down under a running native prompt() call: first waits, then aborts the
// prompts via their signals and waits for them to settle.
async function drainOrAbortGenerations(): Promise<boolean> {
  if (await waitForGenerationsToDrain(MODEL_SWITCH_DRAIN_MS)) {
    return true;
  }
  console.warn(`[LocalLLM] ${activeGenerations} generation(s) still running after ${MODEL_SWITCH_DRAIN_MS}ms, aborting them...`);
  for (const controller of activeGenerationAborts) {
    controller.abort(new Error('Model is being switched'));
  }
  return waitForGenerationsToDrain(MODEL_SWITCH_SETTLE_MS);
}

export async function initializeLocalLLM(modelId?: string): Promise<{ success: boolean; error?: string }> {
  const spec = resolveModel(modelId);

  for (;;) {
    // Already initialized with the requested model
    if (isInitialized && model && currentModelId === spec.id) {
      return { success: true };
    }

    // An init is in flight: await it instead of failing, then re-evaluate
    // (it may have loaded the model we want — or a different one).
    if (initPromise) {
      await initPromise.catch(() => {});
      continue;
    }

    // Throttle retries of a recently failed init of the same model
    if (initError && initErrorModelId === spec.id && Date.now() - lastInitAttempt < INIT_RETRY_DELAY) {
      return { success: false, error: initError };
    }

    initPromise = doInitialize(spec);
    try {
      return await initPromise;
    } finally {
      initPromise = null;
    }
  }
}

async function doInitialize(spec: BuiltinModelSpec): Promise<{ success: boolean; error?: string }> {
  lastInitAttempt = Date.now();

  try {
    // Switching models: drain in-flight generations, then release the old model
    if (model && currentModelId !== spec.id) {
      console.log(`[LocalLLM] Switching model: ${currentModelId} -> ${spec.id}`);
      if (!(await drainOrAbortGenerations())) {
        return { success: false, error: 'Model is busy generating a response. Try again in a moment.' };
      }
      await disposeLocalLLM();
    }

    // Check model availability first
    const availability = await checkLocalLLMAvailable(spec.id);
    if (!availability.available) {
      throw new Error(availability.error);
    }

    const modelPath = getModelPath(spec.id);
    console.log('[LocalLLM] Initializing with model:', modelPath);

    // Dynamic import for ESM module (using dynamicImport to bypass CommonJS transformation)
    if (!llamaModule) {
      ensureAsarModuleResolution();
      const importPath = getNodeLlamaCppImportPath();
      console.log('[LocalLLM] Loading node-llama-cpp module from:', importPath);
      llamaModule = await dynamicImport(importPath);
    }

    const { getLlama } = llamaModule;

    // Initialize llama runtime. build: "never" — inside a packaged app a
    // from-source build can never succeed, so fail fast with a clear error
    // if no prebuilt binary (Metal/CUDA/Vulkan/CPU) matches this machine.
    if (!llama) {
      console.log('[LocalLLM] Initializing llama runtime...');
      llama = await getLlama({ build: 'never' });
      console.log(`[LocalLLM] GPU backend: ${llama.gpu || 'CPU'}`);
    }

    // gpuLayers is intentionally omitted: the "auto" default probes
    // VRAM/unified memory and offloads as many layers as safely fit, on
    // every backend. (A fixed number or "max" throws when it doesn't fit.)
    model = await llama.loadModel({ modelPath });

    // Note: Context is created fresh for each generation to avoid sequence exhaustion
    currentModelId = spec.id;
    isInitialized = true;
    initError = null;
    initErrorModelId = null;
    console.log('[LocalLLM] Initialization complete');

    return { success: true };
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown initialization error';
    console.error('[LocalLLM] Initialization failed:', errorMessage);
    isInitialized = false;

    // Clean up partial state (also clears initError — restore it after)
    await disposeLocalLLM();
    initError = errorMessage;
    initErrorModelId = spec.id;

    return { success: false, error: errorMessage };
  }
}

export async function generateLocalResponse(
  systemPrompt: string,
  userPrompt: string,
  config?: Partial<LLMConfig>
): Promise<{ response?: string; error?: string }> {
  // Merge provided config with defaults
  const llmConfig = { ...DEFAULT_CONFIG, ...config };
  const spec = resolveModel(llmConfig.modelId ?? currentModelId);

  // Ensure the requested model is initialized (also handles model switches;
  // concurrent callers await the same in-flight init instead of failing).
  if (!isInitialized || !model || currentModelId !== spec.id) {
    const initResult = await initializeLocalLLM(spec.id);
    if (!initResult.success) {
      return { error: initResult.error };
    }
  }

  let localContext: any = null;
  let session: any = null;
  const abortController = new AbortController();

  activeGenerations++;
  activeGenerationAborts.add(abortController);

  try {
    const { LlamaChatSession } = llamaModule;

    // Create a fresh context for each request to avoid sequence exhaustion.
    // contextSize {max} clamps to what actually fits in memory right now
    // instead of throwing; the KV cache is allocated here and freed in the
    // finally block, so large contexts cost allocation churn per request.
    console.log(`[LocalLLM] Creating context (size: ≤${llmConfig.contextSize}, batch: ${llmConfig.batchSize}, maxTokens: ${llmConfig.maxTokens})...`);
    localContext = await model.createContext({
      contextSize: { max: llmConfig.contextSize },
      batchSize: llmConfig.batchSize,
    });

    lastResolvedContextSize = localContext.contextSize ?? null;
    if (lastResolvedContextSize !== null && lastResolvedContextSize < llmConfig.contextSize) {
      console.warn(`[LocalLLM] Context clamped to ${lastResolvedContextSize} tokens (requested ${llmConfig.contextSize}) to fit available memory`);
    }

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
      signal: abortController.signal,
    });

    const duration = Date.now() - startTime;
    console.log(`[LocalLLM] Response generated in ${duration}ms`);

    return { response };
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Generation failed';
    console.error('[LocalLLM] Generation error:', errorMessage);
    return { error: errorMessage };
  } finally {
    activeGenerationAborts.delete(abortController);
    activeGenerations--;

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
  currentModelId = null;
  isInitialized = false;
  // Reset the error cache too: a stale error (and its retry throttle) must
  // not carry over to the next init, which may target a different model.
  initError = null;
  initErrorModelId = null;
  lastInitAttempt = 0;
  console.log('[LocalLLM] Disposed');
}

// Dispose only if the given model is the one currently loaded
// (used when its file is deleted from Settings).
export async function disposeIfCurrentModel(modelId: string): Promise<void> {
  if (currentModelId !== modelId) return;
  await drainOrAbortGenerations();
  await disposeLocalLLM();
}

// App-quit teardown: abort any running generation and wait for it to settle
// before releasing the model — disposing under a native prompt() call crashes.
export async function shutdownLocalLLM(): Promise<void> {
  await drainOrAbortGenerations();
  await disposeLocalLLM();
}

export function getLocalLLMStatus(): {
  initialized: boolean;
  initializing: boolean;
  error: string | null;
  modelId: string | null;
  lastContextSize: number | null;
  gpuAcceleration: {
    enabled: boolean;
    type: string;
  };
} {
  // llama.gpu reports the backend actually in use ("metal" | "cuda" | "vulkan" | false)
  const gpuType: string | false = llama?.gpu ?? false;
  return {
    initialized: isInitialized,
    initializing: initPromise !== null,
    error: initError,
    modelId: currentModelId,
    // Resolved size of the most recent generation's context (contexts are
    // per-request, so there is none to inspect between generations).
    lastContextSize: lastResolvedContextSize,
    gpuAcceleration: {
      enabled: Boolean(gpuType),
      type: gpuType ? String(gpuType) : 'CPU',
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

export { DEFAULT_BUILTIN_MODEL_ID };
