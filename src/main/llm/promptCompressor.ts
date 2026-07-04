import * as path from 'path';
import * as fs from 'fs';
import { app } from 'electron';
import { truncateToTokenBudget, estimateTokens } from './localLLM';

// Force real ESM dynamic import (bypasses TypeScript's CommonJS transformation).
// @atjsh/llmlingua-2 and @huggingface/transformers are ESM-only, exactly like
// node-llama-cpp — see localLLM.ts for the same pattern.
const dynamicImport = new Function('specifier', 'return import(specifier)') as (specifier: string) => Promise<any>;

// LLMLingua-2 MobileBERT model (BERT-family / WordPiece tokenization → WithBERTMultilingual).
// Hugging Face repo id; the ONNX weights live under onnx/model.onnx (~99MB).
const COMPRESSOR_MODEL_ID = 'atjsh/llmlingua-2-js-mobilebert-meetingbank';

// State management (module-level singleton, mirrors localLLM.ts)
let compressor: any = null;                 // PromptCompressorLLMLingua2 instance
let isInitialized = false;
let isInitializing = false;
let initError: string | null = null;
let lastInitAttempt = 0;
let initPromise: Promise<{ success: boolean; error?: string }> | null = null;
let asarResolutionPatched = false;

const INIT_RETRY_DELAY = 10000; // 10s between failed init attempts

// Root directory that Transformers.js resolves as <root>/<modelId>/... for local models.
function getCompressorModelDir(): string {
  if (!app.isPackaged) {
    return path.join(process.cwd(), 'models', 'compressor');
  }
  return path.join(process.resourcesPath, 'models', 'compressor');
}

// Absolute path to this specific model's files (config.json, tokenizer, onnx/model.onnx).
function getModelFilesPath(): string {
  return path.join(getCompressorModelDir(), ...COMPRESSOR_MODEL_ID.split('/'));
}

// Resolve an import specifier for an ESM package.
//   dev:      the bare package specifier, so Node's "exports" map picks the
//             canonical ESM entry — the SAME module instance llmlingua-2 imports
//             internally (critical so our env config reaches its transformers).
//   packaged: an explicit file:// path into app.asar.unpacked, bypassing the
//             exports map so native binaries (onnxruntime-node) load from the
//             real filesystem. It points at the same ESM file the bare specifier
//             would resolve to, so both callers share one module instance.
function getImportSpecifier(packageName: string, packagedRelPath: string): string {
  if (!app.isPackaged) {
    return packageName;
  }
  const unpackedPath = path.join(
    process.resourcesPath,
    'app.asar.unpacked', 'node_modules',
    ...packageName.split('/'), ...packagedRelPath.split('/')
  );
  return `file://${unpackedPath}`;
}

// Allow hoisted deps inside app.asar to resolve when packages are loaded from
// app.asar.unpacked (same rationale as localLLM.ts::ensureAsarModuleResolution).
function ensureAsarModuleResolution(): void {
  if (!app.isPackaged || asarResolutionPatched) return;
  asarResolutionPatched = true;

  const Module = require('module');
  const asarNodeModules = path.join(process.resourcesPath, 'app.asar', 'node_modules');
  if (!Module.globalPaths.includes(asarNodeModules)) {
    Module.globalPaths.push(asarNodeModules);
  }
}

// Check whether the compressor model has been downloaded (run: npm run download-compressor).
export function isCompressorModelAvailable(): { available: boolean; error?: string } {
  const dir = getModelFilesPath();
  const configPath = path.join(dir, 'config.json');
  const onnxPath = path.join(dir, 'onnx', 'model.onnx');

  if (!fs.existsSync(configPath) || !fs.existsSync(onnxPath)) {
    return {
      available: false,
      error: `Compressor model not found in ${dir}. Run: npm run download-compressor`,
    };
  }
  return { available: true };
}

// Lazily load and initialize the LLMLingua-2 compressor. Safe to call repeatedly;
// concurrent callers share a single in-flight init promise.
export async function initializeCompressor(): Promise<{ success: boolean; error?: string }> {
  if (isInitialized && compressor) {
    return { success: true };
  }
  if (initPromise) {
    return initPromise;
  }

  // Back off after a recent failure so every keystroke-triggered analysis
  // doesn't retry a broken model load.
  const now = Date.now();
  if (initError && now - lastInitAttempt < INIT_RETRY_DELAY) {
    return { success: false, error: initError };
  }

  initPromise = (async () => {
    isInitializing = true;
    lastInitAttempt = now;
    initError = null;

    try {
      const availability = isCompressorModelAvailable();
      if (!availability.available) {
        throw new Error(availability.error);
      }

      ensureAsarModuleResolution();

      // Configure Transformers.js for fully offline, local-only model loading.
      // This is the same module instance llmlingua-2 imports internally, so the
      // env changes apply to its model/tokenizer loads too.
      const transformers = await dynamicImport(
        getImportSpecifier('@huggingface/transformers', 'dist/transformers.node.mjs')
      );
      const env = transformers.env || transformers.default?.env;
      if (env) {
        env.allowRemoteModels = false;        // never hit the network
        env.allowLocalModels = true;
        env.localModelPath = getCompressorModelDir();
        if (env.backends?.onnx?.wasm) {
          env.backends.onnx.wasm.numThreads = 1; // avoid worker/threading issues in Electron main
        }
      }

      const llmlinguaModule = await dynamicImport(
        getImportSpecifier('@atjsh/llmlingua-2', 'dist/index.js')
      );
      const LLMLingua2 = llmlinguaModule.LLMLingua2 || llmlinguaModule.default?.LLMLingua2;
      if (!LLMLingua2?.WithBERTMultilingual) {
        throw new Error('Failed to load @atjsh/llmlingua-2 (WithBERTMultilingual missing)');
      }

      // js-tiktoken is CommonJS-friendly; used only to measure the compression rate.
      const { Tiktoken } = require('js-tiktoken/lite');
      const o200k_base = require('js-tiktoken/ranks/o200k_base');
      const oaiTokenizer = new Tiktoken(o200k_base.default || o200k_base);

      console.log('[Compressor] Loading LLMLingua-2 MobileBERT model...');
      const startTime = Date.now();
      const { promptCompressor } = await LLMLingua2.WithBERTMultilingual(COMPRESSOR_MODEL_ID, {
        transformerJSConfig: {
          device: 'cpu',
          dtype: 'fp32',
        },
        oaiTokenizer,
        logger: () => {}, // silence the library's verbose default console.log logger
      });

      compressor = promptCompressor;
      isInitialized = true;
      console.log(`[Compressor] Ready in ${Date.now() - startTime}ms`);
      return { success: true };
    } catch (error) {
      initError = error instanceof Error ? error.message : 'Compressor init failed';
      console.error('[Compressor] Initialization error:', initError);
      return { success: false, error: initError };
    } finally {
      isInitializing = false;
      initPromise = null;
    }
  })();

  return initPromise;
}

// Compress `text` down to roughly `targetTokens` tokens using LLMLingua-2.
// Falls back to the existing character-based truncation whenever the compressor
// is unavailable or errors, so analysis never breaks.
export async function compressText(text: string, targetTokens: number): Promise<string> {
  if (!text || targetTokens <= 0) {
    return truncateToTokenBudget(text, targetTokens);
  }

  const availability = isCompressorModelAvailable();
  if (!availability.available) {
    return truncateToTokenBudget(text, targetTokens);
  }

  const init = await initializeCompressor();
  if (!init.success || !compressor) {
    return truncateToTokenBudget(text, targetTokens);
  }

  try {
    const estimated = Math.max(1, estimateTokens(text));
    const rate = Math.min(1, targetTokens / estimated); // fraction of tokens to keep (fallback signal)

    const startTime = Date.now();
    const compressed: string = await compressor.compress(text, {
      rate,
      targetToken: targetTokens, // overrides rate; aim directly for the budget
    });
    console.log(
      `[Compressor] ${estimated} → ~${estimateTokens(compressed)} est. tokens in ${Date.now() - startTime}ms`
    );

    if (!compressed || compressed.trim().length === 0) {
      return truncateToTokenBudget(text, targetTokens);
    }

    // Final guard: never exceed the budget even if compression under-shrinks.
    return truncateToTokenBudget(compressed, targetTokens);
  } catch (error) {
    console.error('[Compressor] Compression failed, falling back to truncation:', error);
    return truncateToTokenBudget(text, targetTokens);
  }
}

// Status for the settings UI / diagnostics.
export function getCompressorStatus(): {
  initialized: boolean;
  initializing: boolean;
  error: string | null;
  modelAvailable: boolean;
  modelId: string;
  modelPath: string;
} {
  return {
    initialized: isInitialized,
    initializing: isInitializing,
    error: initError,
    modelAvailable: isCompressorModelAvailable().available,
    modelId: COMPRESSOR_MODEL_ID,
    modelPath: getModelFilesPath(),
  };
}

// Free the compressor model (called on app quit alongside disposeLocalLLM).
export async function disposeCompressor(): Promise<void> {
  try {
    if (compressor?.model?.dispose) {
      await compressor.model.dispose();
    }
  } catch (e) {
    // ignore
  }
  compressor = null;
  isInitialized = false;
  console.log('[Compressor] Disposed');
}
