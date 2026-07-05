import { useState, useEffect, useMemo } from 'react';
import { X, Languages, Check, Plus, Trash2, RotateCcw, MessageSquare, ChevronDown, ChevronRight, Mic, Shield, ShieldAlert, Download } from 'lucide-react';
import { AISettings, BuiltinModelId, BuiltinModelInfo, BUILTIN_MODELS, SpellcheckLanguage, FeedbackTypeConfig, DEFAULT_FEEDBACK_TYPES, DEFAULT_SYSTEM_PROMPT, DEFAULT_TIP_STYLE, TIP_LANGUAGE_OPTIONS, TipStyleConfig, FeedbackCategory, FEEDBACK_CATEGORY_LABELS, FeedbackTypeConfigWithCategory, SttSettings } from '../../shared/types';

function formatBytes(bytes: number): string {
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
  return `${Math.round(bytes / 1024 ** 2)} MB`;
}

interface SettingsModalProps {
  onClose: () => void;
  onSaved: () => void;
}

function SettingsModal({ onClose, onSaved }: SettingsModalProps) {
  const [settings, setSettings] = useState<AISettings>({
    provider: 'builtin',
    builtinModel: 'qwen2.5-0.5b',
    ollamaModel: 'llama3.2',
    ollamaUrl: 'http://localhost:11434',
    mistralApiKey: '',
    spellcheckEnabled: true,
    spellcheckLanguages: ['en-US'],
    chunkingThresholdMs: 3000,
    llmContextSize: 2048,
    llmMaxTokens: 1536,
    llmBatchSize: 512,
    compressionEnabled: true,
    promptConfig: {
      systemPrompt: DEFAULT_SYSTEM_PROMPT,
      feedbackTypes: DEFAULT_FEEDBACK_TYPES,
      tipStyle: DEFAULT_TIP_STYLE,
    },
    stt: {
      sttProvider: 'mistral-cloud',
      localSttUrl: 'http://localhost:8000',
      qwenSttUrl: 'http://localhost:9000',
      sttTimestamps: true,
      sttDiarize: false,
      sttLanguage: '',
    },
  });
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [testResult, setTestResult] = useState<'success' | 'error' | null>(null);
  const [sttTestResult, setSttTestResult] = useState<'success' | 'error' | null>(null);
  const [availableLanguages, setAvailableLanguages] = useState<SpellcheckLanguage[]>([]);
  const [activeTab, setActiveTab] = useState<'ai' | 'editor' | 'prompts' | 'transcription'>('ai');
  const [encryptionAvailable, setEncryptionAvailable] = useState<boolean | null>(null);

  // Built-in model registry state (installed / RAM cap / in-flight downloads)
  const [builtinModels, setBuiltinModels] = useState<BuiltinModelInfo[]>([]);
  const [activeDownloads, setActiveDownloads] = useState<Record<string, { downloadedBytes: number; totalBytes: number }>>({});
  const [downloadError, setDownloadError] = useState<string | null>(null);

  const refreshBuiltinModels = async () => {
    try {
      const models = await window.api.ai.getBuiltinModels();
      setBuiltinModels(models);
      // Re-attach to downloads already running in the main process
      // (e.g. the modal was closed and reopened mid-download).
      setActiveDownloads((prev) => {
        const next = { ...prev };
        for (const m of models) {
          if (m.download) {
            next[m.id] = { downloadedBytes: m.download.downloadedBytes, totalBytes: m.download.totalBytes };
          }
        }
        return next;
      });
    } catch (error) {
      console.error('[Settings] Failed to load builtin models:', error);
    }
  };

  useEffect(() => {
    loadSettings();
    loadAvailableLanguages();
    loadEncryptionStatus();
    refreshBuiltinModels();
    const unsubscribe = window.api.ai.onDownloadProgress((progress) => {
      setActiveDownloads((prev) => ({
        ...prev,
        [progress.modelId]: { downloadedBytes: progress.downloadedBytes, totalBytes: progress.totalBytes },
      }));
    });
    return unsubscribe;
  }, []);

  const handleModelChange = (modelId: string) => {
    const info = builtinModels.find((m) => m.id === modelId);
    setTestResult(null);
    setDownloadError(null);
    setSettings({
      ...settings,
      builtinModel: modelId as BuiltinModelId,
      // Each model needs its own tuning; carrying the previous model's values
      // over would leave e.g. Phi-3 stuck at a Qwen-sized context.
      ...(info
        ? {
            llmContextSize: Math.min(info.recommendedContextSize, info.effectiveMaxContext),
            llmMaxTokens: info.recommendedMaxTokens,
            llmBatchSize: info.recommendedBatchSize,
          }
        : {}),
    });
  };

  const handleDownload = async (modelId: string) => {
    setDownloadError(null);
    setActiveDownloads((prev) => ({ ...prev, [modelId]: { downloadedBytes: 0, totalBytes: 0 } }));
    const result = await window.api.ai.downloadBuiltinModel(modelId);
    setActiveDownloads((prev) => {
      const next = { ...prev };
      delete next[modelId];
      return next;
    });
    if (!result.success && result.error && result.error !== 'Download cancelled') {
      setDownloadError(result.error);
    }
    await refreshBuiltinModels();
  };

  const handleCancelDownload = async (modelId: string) => {
    await window.api.ai.cancelModelDownload(modelId);
  };

  const handleDeleteModel = async (modelId: string) => {
    const info = builtinModels.find((m) => m.id === modelId);
    if (!confirm(`Delete the downloaded ${info?.label ?? modelId} model file (~${info ? formatBytes(info.approxDownloadSizeMB * 1024 * 1024) : ''})?`)) {
      return;
    }
    const result = await window.api.ai.deleteBuiltinModel(modelId);
    if (!result.success && result.error) {
      setDownloadError(result.error);
    }
    await refreshBuiltinModels();
  };

  const loadSettings = async () => {
    const loaded = await window.api.settings.get();
    // Ensure settings exist for older configurations
    setSettings({
      ...loaded,
      builtinModel: loaded.builtinModel ?? 'qwen2.5-0.5b',
      spellcheckEnabled: loaded.spellcheckEnabled ?? true,
      spellcheckLanguages: loaded.spellcheckLanguages ?? ['en-US'],
      chunkingThresholdMs: loaded.chunkingThresholdMs ?? 3000,
      llmContextSize: loaded.llmContextSize ?? 2048,
      llmMaxTokens: loaded.llmMaxTokens ?? 1536,
      llmBatchSize: loaded.llmBatchSize ?? 512,
      compressionEnabled: loaded.compressionEnabled ?? true,
      promptConfig: {
        systemPrompt: loaded.promptConfig?.systemPrompt ?? DEFAULT_SYSTEM_PROMPT,
        feedbackTypes: loaded.promptConfig?.feedbackTypes ?? DEFAULT_FEEDBACK_TYPES,
        tipStyle: { ...DEFAULT_TIP_STYLE, ...loaded.promptConfig?.tipStyle },
      },
      stt: loaded.stt ?? {
        sttProvider: 'mistral-cloud',
        localSttUrl: 'http://localhost:8000',
        qwenSttUrl: 'http://localhost:9000',
        sttTimestamps: true,
        sttDiarize: false,
        sttLanguage: '',
      },
    });
  };

  const loadAvailableLanguages = async () => {
    const languages = await window.api.spellcheck.getAvailableLanguages();
    setAvailableLanguages(languages);
  };

  const loadEncryptionStatus = async () => {
    const available = await window.api.security.isEncryptionAvailable();
    setEncryptionAvailable(available);
  };

  const toggleLanguage = (code: string) => {
    const current = settings.spellcheckLanguages || [];
    if (current.includes(code)) {
      setSettings({
        ...settings,
        spellcheckLanguages: current.filter((c) => c !== code),
      });
    } else {
      setSettings({
        ...settings,
        spellcheckLanguages: [...current, code],
      });
    }
  };

  const handleSave = async () => {
    setIsSaving(true);
    try {
      await window.api.settings.save(settings);
      onSaved();
      onClose();
    } catch (error) {
      // Keep the modal open so the user can retry (e.g. after allowing keychain access).
      console.error('[Settings] Save failed:', error);
    } finally {
      setIsSaving(false);
    }
  };

  const handleTest = async () => {
    setTestResult(null);
    const connected = await window.api.ai.checkConnection();
    setTestResult(connected ? 'success' : 'error');
  };

  // Close on Escape for keyboard accessibility
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', onKeyDown);
    return () => document.removeEventListener('keydown', onKeyDown);
  }, [onClose]);

  const tipStyle: TipStyleConfig = { ...DEFAULT_TIP_STYLE, ...settings.promptConfig?.tipStyle };

  const updateTipStyle = (updates: Partial<TipStyleConfig>) => {
    setSettings({
      ...settings,
      promptConfig: {
        ...settings.promptConfig,
        tipStyle: { ...tipStyle, ...updates },
      },
    });
  };

  // Prompt configuration helpers
  const updateSystemPrompt = (prompt: string) => {
    setSettings({
      ...settings,
      promptConfig: {
        ...settings.promptConfig,
        systemPrompt: prompt,
      },
    });
  };

  const updateFeedbackType = (id: string, updates: Partial<FeedbackTypeConfig>) => {
    setSettings({
      ...settings,
      promptConfig: {
        ...settings.promptConfig,
        feedbackTypes: settings.promptConfig.feedbackTypes.map((t) =>
          t.id === id ? { ...t, ...updates } : t
        ),
      },
    });
  };

  const addFeedbackType = () => {
    const newId = `custom_${Date.now()}`;
    const newType: FeedbackTypeConfigWithCategory = {
      id: newId,
      label: 'New Type',
      description: 'Description of what this feedback type checks for',
      color: '#888888',
      enabled: true,
      category: 'core', // Custom types go to core category
    };
    setSettings({
      ...settings,
      promptConfig: {
        ...settings.promptConfig,
        feedbackTypes: [...settings.promptConfig.feedbackTypes, newType],
      },
    });
  };

  const removeFeedbackType = (id: string) => {
    setSettings({
      ...settings,
      promptConfig: {
        ...settings.promptConfig,
        feedbackTypes: settings.promptConfig.feedbackTypes.filter((t) => t.id !== id),
      },
    });
  };

  const resetToDefaults = () => {
    if (confirm('Reset all prompts and feedback types to defaults?')) {
      setSettings({
        ...settings,
        promptConfig: {
          systemPrompt: DEFAULT_SYSTEM_PROMPT,
          feedbackTypes: DEFAULT_FEEDBACK_TYPES,
          tipStyle: DEFAULT_TIP_STYLE,
        },
      });
    }
  };

  // Track collapsed categories
  const [collapsedCategories, setCollapsedCategories] = useState<Set<FeedbackCategory>>(
    new Set(['academic', 'strategy', 'cross_cutting', 'meeting']) // Collapse non-core by default
  );

  const toggleCategory = (category: FeedbackCategory) => {
    setCollapsedCategories((prev) => {
      const next = new Set(prev);
      if (next.has(category)) {
        next.delete(category);
      } else {
        next.add(category);
      }
      return next;
    });
  };

  // Group feedback types by category
  const feedbackTypesByCategory = useMemo(() => {
    const types = settings.promptConfig?.feedbackTypes || DEFAULT_FEEDBACK_TYPES;
    const grouped: Record<FeedbackCategory, FeedbackTypeConfigWithCategory[]> = {
      core: [],
      academic: [],
      strategy: [],
      cross_cutting: [],
      meeting: [],
    };

    types.forEach((type) => {
      const typedType = type as FeedbackTypeConfigWithCategory;
      const category = typedType.category || 'core';
      if (grouped[category]) {
        grouped[category].push(typedType);
      } else {
        grouped.core.push(typedType);
      }
    });

    return grouped;
  }, [settings.promptConfig?.feedbackTypes]);

  // Enable/disable all types in a category
  const toggleCategoryEnabled = (category: FeedbackCategory, enabled: boolean) => {
    const types = settings.promptConfig?.feedbackTypes || DEFAULT_FEEDBACK_TYPES;
    const updatedTypes = types.map((type) => {
      const typedType = type as FeedbackTypeConfigWithCategory;
      if ((typedType.category || 'core') === category) {
        return { ...typedType, enabled };
      }
      return typedType;
    });
    setSettings({
      ...settings,
      promptConfig: {
        ...settings.promptConfig,
        feedbackTypes: updatedTypes,
      },
    });
  };

  // Count enabled types in a category
  const countEnabled = (category: FeedbackCategory) => {
    const types = feedbackTypesByCategory[category];
    return types.filter((t) => t.enabled).length;
  };

  // Built-in model derived state. Until the IPC round-trip resolves, fall
  // back to the static registry so the picker isn't empty on first paint.
  const modelOptions: (BuiltinModelInfo | (typeof BUILTIN_MODELS)[number])[] =
    builtinModels.length > 0 ? builtinModels : BUILTIN_MODELS;
  const selectedModel = builtinModels.find((m) => m.id === settings.builtinModel);
  const selectedDownload = activeDownloads[settings.builtinModel];
  const contextCeiling = selectedModel?.effectiveMaxContext ?? 8192;
  const selectedSpec = selectedModel ?? BUILTIN_MODELS.find((m) => m.id === settings.builtinModel);
  const kvCostBytes = selectedSpec ? selectedSpec.kvBytesPerToken * (settings.llmContextSize || 0) : null;
  const selectedModelMissing = selectedModel ? !selectedModel.installed : false;
  const downloadPercent =
    selectedDownload && selectedDownload.totalBytes > 0
      ? Math.min(100, Math.floor((selectedDownload.downloadedBytes / selectedDownload.totalBytes) * 100))
      : 0;

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true" aria-label="Settings">
        <div className="modal-header">
          <h2 className="modal-title">Settings</h2>
          <button className="modal-close" onClick={onClose} aria-label="Close settings">
            <X size={20} />
          </button>
        </div>

        {/* Tabs */}
        <div className="modal-tabs">
          <button
            className={`modal-tab ${activeTab === 'ai' ? 'active' : ''}`}
            onClick={() => setActiveTab('ai')}
          >
            AI Provider
          </button>
          <button
            className={`modal-tab ${activeTab === 'prompts' ? 'active' : ''}`}
            onClick={() => setActiveTab('prompts')}
          >
            <MessageSquare size={16} />
            Prompts
          </button>
          <button
            className={`modal-tab ${activeTab === 'transcription' ? 'active' : ''}`}
            onClick={() => setActiveTab('transcription')}
          >
            <Mic size={16} />
            Transcription
          </button>
          <button
            className={`modal-tab ${activeTab === 'editor' ? 'active' : ''}`}
            onClick={() => setActiveTab('editor')}
          >
            <Languages size={16} />
            Spellcheck
          </button>
        </div>

        <div className="modal-body">
          {activeTab === 'ai' && (
            <>
              <div className="form-group">
                <label className="form-label">AI Provider</label>
                <select
                  className="form-select"
                  value={settings.provider}
                  onChange={(e) =>
                    setSettings({ ...settings, provider: e.target.value as 'builtin' | 'ollama' | 'mistral' })
                  }
                >
                  <option value="builtin">Built-in AI</option>
                  <option value="ollama">Ollama (Local)</option>
                  <option value="mistral">Mistral API (Cloud)</option>
                </select>
                <p className="form-hint">
                  {settings.provider === 'builtin'
                    ? 'Runs a local model entirely on your device. Works offline, no external setup required.'
                    : settings.provider === 'ollama'
                    ? 'Uses a local LLM via Ollama for privacy-first AI feedback.'
                    : 'Uses Mistral API for AI feedback. Requires internet connection.'}
                </p>
              </div>

              <div className="form-group">
                <label className="form-label" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <span>Prompt Compression (LLMLingua-2)</span>
                  <button
                    className={`toggle-switch ${settings.compressionEnabled ? 'active' : ''}`}
                    onClick={() => setSettings({ ...settings, compressionEnabled: !settings.compressionEnabled })}
                  >
                    <span className="toggle-slider" />
                  </button>
                </label>
                <p className="form-hint">
                  Semantically compresses long notes to fit the token budget (keeps the most important content
                  instead of cutting off the end). Runs fully on-device. Requires a one-time model download:
                  <code> npm run download-compressor</code>. Falls back to simple truncation if the model isn't installed.
                </p>
              </div>

              {settings.provider === 'builtin' && (
                <>
                  <div className="form-group">
                    <label className="form-label">Built-in Model</label>
                    <select
                      className="form-select"
                      value={settings.builtinModel}
                      onChange={(e) => handleModelChange(e.target.value)}
                    >
                      {modelOptions.map((m) => (
                        <option key={m.id} value={m.id}>
                          {m.label} — {m.paramCount} params, ~{formatBytes(m.approxDownloadSizeMB * 1024 * 1024)}
                          {'installed' in m ? (m.installed ? '' : ' (not downloaded)') : ''}
                        </option>
                      ))}
                    </select>
                    {selectedSpec && (
                      <p className="form-hint" style={{ background: 'var(--bg-tertiary)', padding: '12px', borderRadius: '6px', marginTop: '8px' }}>
                        {selectedSpec.description} Runs entirely on your device.
                      </p>
                    )}
                  </div>

                  {/* Download flow: shown until the selected model's file exists locally */}
                  {selectedModelMissing && selectedModel && (
                    <div className="form-group">
                      {selectedDownload ? (
                        <div style={{ background: 'var(--bg-tertiary)', padding: '12px', borderRadius: '8px', border: '1px solid var(--border-subtle)' }}>
                          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '12px', color: 'var(--text-secondary)', marginBottom: '8px' }}>
                            <span>Downloading {selectedModel.label}…</span>
                            <span>
                              {formatBytes(selectedDownload.downloadedBytes)}
                              {selectedDownload.totalBytes > 0 ? ` / ${formatBytes(selectedDownload.totalBytes)} (${downloadPercent}%)` : ''}
                            </span>
                          </div>
                          <div style={{ height: '6px', background: 'var(--bg-secondary)', borderRadius: '3px', overflow: 'hidden' }}>
                            <div style={{ height: '100%', width: `${downloadPercent}%`, background: 'var(--accent-color)', transition: 'width 0.3s ease' }} />
                          </div>
                          <button
                            className="btn btn-secondary"
                            style={{ marginTop: '10px', fontSize: '11px', padding: '6px 12px' }}
                            onClick={() => handleCancelDownload(selectedModel.id)}
                          >
                            Cancel Download
                          </button>
                          <p className="form-hint" style={{ marginTop: '6px' }}>
                            A cancelled or interrupted download resumes from where it stopped.
                          </p>
                        </div>
                      ) : (
                        <button
                          className="btn btn-primary"
                          style={{ width: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '6px' }}
                          onClick={() => handleDownload(selectedModel.id)}
                        >
                          <Download size={16} />
                          Download {selectedModel.label} (~{formatBytes(selectedModel.approxDownloadSizeMB * 1024 * 1024)})
                        </button>
                      )}
                      {downloadError && (
                        <p className="form-hint" style={{ color: 'var(--error-color)', marginTop: '8px' }}>
                          {downloadError}
                        </p>
                      )}
                    </div>
                  )}

                  {/* Delete affordance for models downloaded into the app's data dir */}
                  {selectedModel?.installed && selectedModel.deletable && (
                    <div className="form-group">
                      <button
                        className="btn btn-secondary"
                        style={{ fontSize: '11px', padding: '6px 12px', display: 'flex', alignItems: 'center', gap: '4px' }}
                        onClick={() => handleDeleteModel(selectedModel.id)}
                      >
                        <Trash2 size={12} />
                        Delete downloaded model file
                      </button>
                    </div>
                  )}

                  <div className="form-group">
                    <label className="form-label">Chunking Threshold (ms)</label>
                    <input
                      type="number"
                      className="form-input"
                      min="500"
                      max="10000"
                      step="100"
                      value={settings.chunkingThresholdMs}
                      onChange={(e) => setSettings({ ...settings, chunkingThresholdMs: parseInt(e.target.value) || 3000 })}
                      style={{ padding: '10px 14px', background: 'var(--bg-tertiary)', border: '1px solid var(--border-color)', borderRadius: '8px', color: 'var(--text-primary)', fontSize: '14px' }}
                    />
                    <p className="form-hint">
                      If AI response takes longer than this threshold, the next request will use only the current section (chunked)
                      instead of the full note context. This improves response times on slower hardware.
                    </p>
                    <div style={{ background: 'var(--bg-tertiary)', padding: '10px 12px', borderRadius: '6px', marginTop: '8px', fontSize: '11px', color: 'var(--text-secondary)', lineHeight: 1.6 }}>
                      <strong style={{ color: 'var(--text-primary)' }}>Guidance:</strong><br />
                      • <strong>1000-2000ms:</strong> Aggressive chunking, faster but less context<br />
                      • <strong>3000ms (default):</strong> Balanced for most hardware<br />
                      • <strong>5000-10000ms:</strong> Prefer full context, accepts slower responses
                    </div>
                  </div>

                  {/* Advanced Settings Toggle */}
                  <div className="form-group">
                    <button
                      className="btn btn-secondary"
                      onClick={() => setShowAdvanced(!showAdvanced)}
                      style={{ width: '100%', justifyContent: 'center' }}
                    >
                      {showAdvanced ? 'Hide' : 'Show'} Advanced Settings
                    </button>
                  </div>

                  {showAdvanced && (
                    <>
                      {/* Recommendations Box */}
                      {selectedSpec && (
                        <div className="form-group">
                          <div style={{ background: 'var(--bg-tertiary)', padding: '12px', borderRadius: '8px', border: '1px solid var(--border-subtle)' }}>
                            <p style={{ fontSize: '12px', fontWeight: 600, color: 'var(--accent-color)', marginBottom: '8px' }}>
                              Recommended for {selectedSpec.label}:
                            </p>
                            <div style={{ fontSize: '11px', color: 'var(--text-secondary)', lineHeight: 1.6 }}>
                              <div>• <strong>Context Size:</strong> {selectedSpec.recommendedContextSize} tokens</div>
                              <div>• <strong>Max Output:</strong> {selectedSpec.recommendedMaxTokens} tokens</div>
                              <div>• <strong>Batch Size:</strong> {selectedSpec.recommendedBatchSize}</div>
                            </div>
                            <button
                              type="button"
                              className="btn btn-secondary"
                              style={{ marginTop: '10px', fontSize: '11px', padding: '6px 12px' }}
                              onClick={() => setSettings({
                                ...settings,
                                llmContextSize: Math.min(selectedSpec.recommendedContextSize, contextCeiling),
                                llmMaxTokens: selectedSpec.recommendedMaxTokens,
                                llmBatchSize: selectedSpec.recommendedBatchSize,
                              })}
                            >
                              Apply Recommended Settings
                            </button>
                          </div>
                        </div>
                      )}

                      <div className="form-group">
                        <label className="form-label">Context Size (tokens)</label>
                        <input
                          type="number"
                          className="form-input"
                          min="512"
                          max={contextCeiling}
                          step="256"
                          value={settings.llmContextSize}
                          onChange={(e) => setSettings({ ...settings, llmContextSize: parseInt(e.target.value) || 2048 })}
                          style={{ padding: '10px 14px', background: 'var(--bg-tertiary)', border: '1px solid var(--border-color)', borderRadius: '8px', color: 'var(--text-primary)', fontSize: '14px' }}
                        />
                        <p className="form-hint">
                          How much input text the model can process. Range: 512–{contextCeiling.toLocaleString()} (capped by this machine's RAM for the selected model).
                          {kvCostBytes !== null && (
                            <> Memory cost at the current value: ~{formatBytes(kvCostBytes)} of KV cache.</>
                          )}
                          {' '}Higher = more context but slower; if memory runs short at generation time, the context is automatically reduced to fit.
                        </p>
                        {settings.llmContextSize > contextCeiling && (
                          <p className="form-hint" style={{ color: 'var(--warning-color)' }}>
                            Above the ~{contextCeiling.toLocaleString()}-token cap for this machine — the value will be clamped when generating.
                          </p>
                        )}
                      </div>

                      <div className="form-group">
                        <label className="form-label">Max Output Tokens</label>
                        <input
                          type="number"
                          className="form-input"
                          min="256"
                          max="4096"
                          step="128"
                          value={settings.llmMaxTokens}
                          onChange={(e) => setSettings({ ...settings, llmMaxTokens: parseInt(e.target.value) || 1536 })}
                          style={{ padding: '10px 14px', background: 'var(--bg-tertiary)', border: '1px solid var(--border-color)', borderRadius: '8px', color: 'var(--text-primary)', fontSize: '14px' }}
                        />
                        <p className="form-hint">
                          Maximum length of AI responses. Range: 256-4096. Higher = more detailed suggestions.
                        </p>
                      </div>

                      <div className="form-group">
                        <label className="form-label">Batch Size</label>
                        <input
                          type="number"
                          className="form-input"
                          min="128"
                          max="2048"
                          step="64"
                          value={settings.llmBatchSize}
                          onChange={(e) => setSettings({ ...settings, llmBatchSize: parseInt(e.target.value) || 512 })}
                          style={{ padding: '10px 14px', background: 'var(--bg-tertiary)', border: '1px solid var(--border-color)', borderRadius: '8px', color: 'var(--text-primary)', fontSize: '14px' }}
                        />
                        <p className="form-hint">
                          Inference batch size. Range: 128-2048. Higher = faster but uses more memory.
                        </p>
                      </div>

                      <div className="form-group">
                        <p className="form-hint" style={{ background: 'var(--bg-tertiary)', padding: '12px', borderRadius: '6px' }}>
                          <strong>Note:</strong> Changes apply from the next analysis — no restart needed.
                          Switching models unloads the current one and loads the new one in the background.
                        </p>
                      </div>
                    </>
                  )}
                </>
              )}

              {settings.provider === 'ollama' && (
                <>
                  <div className="form-group">
                    <label className="form-label">Ollama URL</label>
                    <input
                      type="text"
                      className="form-input"
                      value={settings.ollamaUrl}
                      onChange={(e) => setSettings({ ...settings, ollamaUrl: e.target.value })}
                      placeholder="http://localhost:11434"
                    />
                    <p className="form-hint">Default: http://localhost:11434</p>
                  </div>
                  <div className="form-group">
                    <label className="form-label">Model Name</label>
                    <input
                      type="text"
                      className="form-input"
                      value={settings.ollamaModel}
                      onChange={(e) => setSettings({ ...settings, ollamaModel: e.target.value })}
                      placeholder="llama3.2"
                    />
                    <p className="form-hint">
                      Recommended: llama3.2, mistral, or phi3 for M2 MacBooks
                    </p>
                  </div>
                </>
              )}

              {settings.provider === 'mistral' && (
                <div className="form-group">
                  <label className="form-label" style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                    Mistral API Key
                    {encryptionAvailable !== null && (
                      <span
                        style={{
                          display: 'inline-flex',
                          alignItems: 'center',
                          gap: '4px',
                          fontSize: '11px',
                          color: encryptionAvailable ? 'var(--success-color)' : 'var(--warning-color)',
                        }}
                        title={
                          encryptionAvailable
                            ? 'API key is encrypted at rest using OS keychain'
                            : 'OS encryption unavailable; key stored without encryption'
                        }
                      >
                        {encryptionAvailable ? <Shield size={14} /> : <ShieldAlert size={14} />}
                        {encryptionAvailable ? 'Encrypted' : 'Unencrypted'}
                      </span>
                    )}
                  </label>
                  <input
                    type="password"
                    className="form-input"
                    value={settings.mistralApiKey}
                    onChange={(e) => setSettings({ ...settings, mistralApiKey: e.target.value })}
                    placeholder="Enter your Mistral API key"
                  />
                  <p className="form-hint">
                    Get your API key from{' '}
                    <a
                      href="https://console.mistral.ai/"
                      target="_blank"
                      rel="noopener noreferrer"
                      style={{ color: 'var(--accent-color)' }}
                    >
                      console.mistral.ai
                    </a>
                    . Your key is stored securely using OS-level encryption and never sent back to this window —
                    leave the field unchanged to keep the saved key, or clear it to remove it.
                  </p>
                </div>
              )}

              <div className="form-group">
                <button
                  className="btn btn-secondary"
                  onClick={handleTest}
                  disabled={settings.provider === 'builtin' && selectedModelMissing}
                  title={settings.provider === 'builtin' && selectedModelMissing ? 'Download the selected model first' : undefined}
                  style={{ width: '100%' }}
                >
                  Test Connection
                </button>
                {testResult && (
                  <p
                    className="form-hint"
                    style={{
                      color: testResult === 'success' ? 'var(--success-color)' : 'var(--error-color)',
                      marginTop: '8px',
                    }}
                  >
                    {testResult === 'success'
                      ? 'Connection successful!'
                      : 'Connection failed. Please check your settings.'}
                  </p>
                )}
              </div>
            </>
          )}

          {activeTab === 'prompts' && (
            <>
              {/* Reset to Defaults */}
              <div className="form-group">
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '16px' }}>
                  <span style={{ fontSize: '13px', color: 'var(--text-secondary)' }}>
                    Customize the AI prompts and feedback types
                  </span>
                  <button
                    className="btn btn-secondary"
                    onClick={resetToDefaults}
                    style={{ fontSize: '11px', padding: '6px 12px', display: 'flex', alignItems: 'center', gap: '4px' }}
                  >
                    <RotateCcw size={12} />
                    Reset Defaults
                  </button>
                </div>
              </div>

              {/* Tip Style */}
              <div className="form-group">
                <label className="form-label">Tip Style</label>
                <p className="form-hint" style={{ marginBottom: '12px' }}>
                  Control how the AI writes its tips: how detailed, in what tone and language, and how many at once.
                </p>

                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '12px' }}>
                  <div>
                    <label className="form-label" style={{ fontSize: '12px' }} htmlFor="tip-detail">Detail level</label>
                    <select
                      id="tip-detail"
                      className="form-select"
                      value={tipStyle.detailLevel}
                      onChange={(e) => updateTipStyle({ detailLevel: e.target.value as TipStyleConfig['detailLevel'] })}
                    >
                      <option value="brief">Brief - short, scannable hints</option>
                      <option value="standard">Standard - balanced</option>
                      <option value="detailed">Detailed - ready-to-insert paragraphs</option>
                    </select>
                  </div>
                  <div>
                    <label className="form-label" style={{ fontSize: '12px' }} htmlFor="tip-tone">Tone</label>
                    <select
                      id="tip-tone"
                      className="form-select"
                      value={tipStyle.tone}
                      onChange={(e) => updateTipStyle({ tone: e.target.value as TipStyleConfig['tone'] })}
                    >
                      <option value="neutral">Neutral</option>
                      <option value="academic">Academic</option>
                      <option value="direct">Direct</option>
                      <option value="encouraging">Encouraging</option>
                    </select>
                  </div>
                  <div>
                    <label className="form-label" style={{ fontSize: '12px' }} htmlFor="tip-max">Tips per analysis</label>
                    <select
                      id="tip-max"
                      className="form-select"
                      value={tipStyle.maxTips}
                      onChange={(e) => updateTipStyle({ maxTips: parseInt(e.target.value, 10) })}
                    >
                      {[1, 2, 3, 4, 5, 6].map((n) => (
                        <option key={n} value={n}>{n}</option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <label className="form-label" style={{ fontSize: '12px' }} htmlFor="tip-language">Tip language</label>
                    <select
                      id="tip-language"
                      className="form-select"
                      value={tipStyle.language}
                      onChange={(e) => updateTipStyle({ language: e.target.value })}
                    >
                      {TIP_LANGUAGE_OPTIONS.map((opt) => (
                        <option key={opt.value} value={opt.value}>{opt.label}</option>
                      ))}
                    </select>
                  </div>
                </div>

                <div style={{ marginTop: '12px' }}>
                  <label className="form-label" style={{ fontSize: '12px' }} htmlFor="tip-guidance">Custom guidance (optional)</label>
                  <textarea
                    id="tip-guidance"
                    value={tipStyle.customGuidance}
                    onChange={(e) => updateTipStyle({ customGuidance: e.target.value })}
                    placeholder='e.g. "Always propose at least one concrete source" or "Focus on counterarguments"'
                    style={{
                      width: '100%',
                      minHeight: '60px',
                      padding: '10px 12px',
                      background: 'var(--bg-tertiary)',
                      border: '1px solid var(--border-color)',
                      borderRadius: '8px',
                      color: 'var(--text-primary)',
                      fontSize: '12px',
                      resize: 'vertical',
                      lineHeight: 1.5,
                    }}
                  />
                  <p className="form-hint">
                    Added to every analysis request, on top of the system prompt below.
                  </p>
                </div>
              </div>

              {/* System Prompt */}
              <div className="form-group">
                <label className="form-label">System Prompt</label>
                <textarea
                  value={settings.promptConfig?.systemPrompt || DEFAULT_SYSTEM_PROMPT}
                  onChange={(e) => updateSystemPrompt(e.target.value)}
                  style={{
                    width: '100%',
                    minHeight: '200px',
                    padding: '12px',
                    background: 'var(--bg-tertiary)',
                    border: '1px solid var(--border-color)',
                    borderRadius: '8px',
                    color: 'var(--text-primary)',
                    fontSize: '12px',
                    fontFamily: 'monospace',
                    resize: 'vertical',
                    lineHeight: 1.5,
                  }}
                />
                <p className="form-hint">
                  Available variables: {'{{topic}}'}, {'{{section}}'}, {'{{otherSections}}'}, {'{{feedbackTypes}}'}
                </p>
              </div>

              {/* Feedback Types */}
              <div className="form-group">
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '12px' }}>
                  <label className="form-label" style={{ marginBottom: 0 }}>Feedback Types</label>
                  <button
                    className="btn btn-secondary"
                    onClick={addFeedbackType}
                    style={{ fontSize: '11px', padding: '6px 12px', display: 'flex', alignItems: 'center', gap: '4px' }}
                  >
                    <Plus size={12} />
                    Add Custom
                  </button>
                </div>

                <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
                  {(Object.keys(FEEDBACK_CATEGORY_LABELS) as FeedbackCategory[]).map((category) => {
                    const types = feedbackTypesByCategory[category];
                    if (types.length === 0) return null;
                    const isCollapsed = collapsedCategories.has(category);
                    const enabledCount = countEnabled(category);
                    const allEnabled = enabledCount === types.length;
                    const noneEnabled = enabledCount === 0;

                    return (
                      <div
                        key={category}
                        style={{
                          background: 'var(--bg-tertiary)',
                          border: '1px solid var(--border-subtle)',
                          borderRadius: '10px',
                          overflow: 'hidden',
                        }}
                      >
                        {/* Category Header */}
                        <div
                          style={{
                            display: 'flex',
                            alignItems: 'center',
                            justifyContent: 'space-between',
                            padding: '10px 12px',
                            background: 'var(--bg-secondary)',
                            borderBottom: isCollapsed ? 'none' : '1px solid var(--border-subtle)',
                            cursor: 'pointer',
                          }}
                          onClick={() => toggleCategory(category)}
                        >
                          <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                            {isCollapsed ? <ChevronRight size={16} /> : <ChevronDown size={16} />}
                            <span style={{ fontWeight: 600, fontSize: '13px', color: 'var(--text-primary)' }}>
                              {FEEDBACK_CATEGORY_LABELS[category]}
                            </span>
                            <span style={{ fontSize: '11px', color: 'var(--text-muted)', marginLeft: '4px' }}>
                              ({enabledCount}/{types.length} enabled)
                            </span>
                          </div>
                          <div style={{ display: 'flex', gap: '6px' }} onClick={(e) => e.stopPropagation()}>
                            <button
                              className="btn btn-secondary"
                              onClick={() => toggleCategoryEnabled(category, true)}
                              disabled={allEnabled}
                              style={{ fontSize: '10px', padding: '3px 8px', opacity: allEnabled ? 0.5 : 1 }}
                            >
                              All On
                            </button>
                            <button
                              className="btn btn-secondary"
                              onClick={() => toggleCategoryEnabled(category, false)}
                              disabled={noneEnabled}
                              style={{ fontSize: '10px', padding: '3px 8px', opacity: noneEnabled ? 0.5 : 1 }}
                            >
                              All Off
                            </button>
                          </div>
                        </div>

                        {/* Category Types */}
                        {!isCollapsed && (
                          <div style={{ padding: '8px', display: 'flex', flexDirection: 'column', gap: '6px' }}>
                            {types.map((type) => (
                              <div
                                key={type.id}
                                style={{
                                  background: 'var(--bg-secondary)',
                                  border: '1px solid var(--border-color)',
                                  borderRadius: '6px',
                                  padding: '10px',
                                }}
                              >
                                <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '6px' }}>
                                  {/* Color picker */}
                                  <input
                                    type="color"
                                    value={type.color}
                                    onChange={(e) => updateFeedbackType(type.id, { color: e.target.value })}
                                    style={{
                                      width: '24px',
                                      height: '24px',
                                      padding: 0,
                                      border: 'none',
                                      borderRadius: '4px',
                                      cursor: 'pointer',
                                    }}
                                  />

                                  {/* ID (editable) */}
                                  <input
                                    type="text"
                                    value={type.id}
                                    onChange={(e) => {
                                      const newId = e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '');
                                      if (newId) {
                                        const types = settings.promptConfig.feedbackTypes.map((t) =>
                                          t.id === type.id ? { ...t, id: newId } : t
                                        );
                                        setSettings({
                                          ...settings,
                                          promptConfig: { ...settings.promptConfig, feedbackTypes: types },
                                        });
                                      }
                                    }}
                                    placeholder="id"
                                    style={{
                                      width: '100px',
                                      padding: '4px 6px',
                                      background: 'var(--bg-tertiary)',
                                      border: '1px solid var(--border-color)',
                                      borderRadius: '4px',
                                      color: 'var(--text-muted)',
                                      fontSize: '10px',
                                      fontFamily: 'monospace',
                                    }}
                                  />

                                  {/* Label */}
                                  <input
                                    type="text"
                                    value={type.label}
                                    onChange={(e) => updateFeedbackType(type.id, { label: e.target.value })}
                                    placeholder="Label"
                                    style={{
                                      flex: 1,
                                      padding: '4px 8px',
                                      background: 'var(--bg-tertiary)',
                                      border: '1px solid var(--border-color)',
                                      borderRadius: '4px',
                                      color: 'var(--text-primary)',
                                      fontSize: '12px',
                                    }}
                                  />

                                  {/* Enable/Disable toggle */}
                                  <button
                                    className={`toggle-switch ${type.enabled ? 'active' : ''}`}
                                    onClick={() => updateFeedbackType(type.id, { enabled: !type.enabled })}
                                    style={{ width: '36px', height: '20px', flexShrink: 0 }}
                                  >
                                    <span className="toggle-slider" style={{ width: '14px', height: '14px' }} />
                                  </button>

                                  {/* Delete button */}
                                  <button
                                    onClick={() => removeFeedbackType(type.id)}
                                    style={{
                                      padding: '4px',
                                      background: 'transparent',
                                      border: 'none',
                                      color: 'var(--text-muted)',
                                      cursor: 'pointer',
                                      borderRadius: '4px',
                                    }}
                                    title="Remove this feedback type"
                                  >
                                    <Trash2 size={14} />
                                  </button>
                                </div>

                                {/* Description */}
                                <input
                                  type="text"
                                  value={type.description}
                                  onChange={(e) => updateFeedbackType(type.id, { description: e.target.value })}
                                  placeholder="Description of what this feedback type checks for"
                                  style={{
                                    width: '100%',
                                    padding: '5px 8px',
                                    background: 'var(--bg-tertiary)',
                                    border: '1px solid var(--border-color)',
                                    borderRadius: '4px',
                                    color: 'var(--text-secondary)',
                                    fontSize: '11px',
                                  }}
                                />
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>

                <p className="form-hint" style={{ marginTop: '12px' }}>
                  Feedback types define the categories of suggestions the AI will provide.
                  Enable the types relevant to your work. The AI will auto-detect content type (research, strategy, meeting notes).
                </p>
              </div>
            </>
          )}

          {activeTab === 'transcription' && (
            <>
              <div className="form-group">
                <p className="form-hint" style={{ background: 'var(--bg-tertiary)', padding: '12px', borderRadius: '6px', marginBottom: '16px' }}>
                  Drag and drop audio files (MP3, WAV, FLAC, etc.) onto any note to automatically transcribe them.
                  Choose between Mistral Voxtral (cloud or local) and Qwen3-ASR edge models.
                </p>
              </div>

              <div className="form-group">
                <label className="form-label">Transcription Provider</label>
                <select
                  className="form-select"
                  value={settings.stt.sttProvider}
                  onChange={(e) =>
                    setSettings({
                      ...settings,
                      stt: { ...settings.stt, sttProvider: e.target.value as SttSettings['sttProvider'] },
                    })
                  }
                >
                  <option value="mistral-cloud">Mistral Cloud API (Voxtral Transcribe 2)</option>
                  <option value="mistral-local">Mistral Local (Voxtral Mini 3B Edge)</option>
                  <option value="qwen-edge">Qwen3-ASR-0.6B Edge (Local)</option>
                </select>
                <p className="form-hint">
                  {settings.stt.sttProvider === 'mistral-cloud'
                    ? 'Uses Mistral\'s cloud API ($0.003/min). Requires a Mistral API key. Best accuracy with diarization.'
                    : settings.stt.sttProvider === 'mistral-local'
                    ? 'Self-hosted Voxtral Mini 3B (Apache 2.0, ~3B params, ~5GB quantized). Requires GPU with ≥10GB VRAM.'
                    : 'Ultra-lightweight Qwen3-ASR-0.6B (Apache 2.0, ~1.3GB Q8). Runs on CPU. Supports 52 languages.'}
                </p>
              </div>

              {/* Mistral Cloud: API key */}
              {settings.stt.sttProvider === 'mistral-cloud' && !settings.mistralApiKey && (
                <div className="form-group">
                  <p className="form-hint" style={{ background: 'var(--warning-glow)', padding: '12px', borderRadius: '6px', color: 'var(--warning-color)' }}>
                    Mistral API key is required. Set it in the <strong>AI Provider</strong> tab or enter it here:
                  </p>
                  <input
                    type="password"
                    className="form-input"
                    value={settings.mistralApiKey}
                    onChange={(e) => setSettings({ ...settings, mistralApiKey: e.target.value })}
                    placeholder="Enter your Mistral API key"
                    style={{ marginTop: '8px' }}
                  />
                  <p className="form-hint" style={{ marginTop: '4px' }}>
                    Your key is stored securely using OS-level encryption.
                  </p>
                </div>
              )}

              {/* Mistral Local: endpoint URL + setup guide */}
              {settings.stt.sttProvider === 'mistral-local' && (
                <div className="form-group">
                  <label className="form-label">Voxtral Local Endpoint</label>
                  <input
                    type="text"
                    className="form-input"
                    value={settings.stt.localSttUrl}
                    onChange={(e) =>
                      setSettings({
                        ...settings,
                        stt: { ...settings.stt, localSttUrl: e.target.value },
                      })
                    }
                    placeholder="http://localhost:8000"
                  />
                  <p className="form-hint">
                    Posts to <code>{settings.stt.localSttUrl}/v1/audio/transcriptions</code>
                  </p>
                  <div style={{ background: 'var(--bg-tertiary)', padding: '10px 12px', borderRadius: '6px', marginTop: '8px', fontSize: '11px', color: 'var(--text-secondary)', lineHeight: 1.6 }}>
                    <strong style={{ color: 'var(--text-primary)' }}>Voxtral Mini 3B Setup:</strong><br />
                    1. Install vLLM: <code>pip install vllm</code><br />
                    2. Serve: <code>vllm serve mistralai/Voxtral-Mini-3B-2507 --port 8000</code><br />
                    3. Or use GGUF with llama.cpp: <code>ggml-org/Voxtral-Mini-3B-2507-GGUF</code><br />
                    <em>Requires GPU with ≥10GB VRAM (FP16) or ≥5GB (FP8 quantized)</em>
                  </div>
                </div>
              )}

              {/* Qwen Edge: endpoint URL + setup guide */}
              {settings.stt.sttProvider === 'qwen-edge' && (
                <div className="form-group">
                  <label className="form-label">Qwen3-ASR Endpoint</label>
                  <input
                    type="text"
                    className="form-input"
                    value={settings.stt.qwenSttUrl || 'http://localhost:9000'}
                    onChange={(e) =>
                      setSettings({
                        ...settings,
                        stt: { ...settings.stt, qwenSttUrl: e.target.value },
                      })
                    }
                    placeholder="http://localhost:9000"
                  />
                  <p className="form-hint">
                    Tries <code>/v1/audio/transcriptions</code> then <code>/asr</code> endpoint.
                  </p>
                  <div style={{ background: 'var(--bg-tertiary)', padding: '10px 12px', borderRadius: '6px', marginTop: '8px', fontSize: '11px', color: 'var(--text-secondary)', lineHeight: 1.6 }}>
                    <strong style={{ color: 'var(--text-primary)' }}>Qwen3-ASR-0.6B Setup (C++ / GGUF):</strong><br />
                    1. Clone: <code>git clone https://github.com/predict-woo/qwen3-asr.cpp</code><br />
                    2. Build: <code>cmake -B build &amp;&amp; cmake --build build</code><br />
                    3. Download model: <code>Q8_0 GGUF (~1.3GB)</code><br />
                    4. Run server: <code>./build/bin/server -m model.gguf --port 9000</code><br />
                    <br />
                    <strong style={{ color: 'var(--text-primary)' }}>Or via Python (Transformers):</strong><br />
                    <code>pip install transformers torch</code> then serve with a FastAPI wrapper.<br />
                    <br />
                    <em>Runs on CPU (~1.3GB RAM). No GPU required. 52 languages supported.</em>
                  </div>
                </div>
              )}

              {/* Transcription options */}
              <div className="form-group">
                <label className="form-label" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <span>Word-level Timestamps</span>
                  <button
                    className={`toggle-switch ${settings.stt.sttTimestamps ? 'active' : ''}`}
                    onClick={() =>
                      setSettings({
                        ...settings,
                        stt: { ...settings.stt, sttTimestamps: !settings.stt.sttTimestamps },
                      })
                    }
                  >
                    <span className="toggle-slider" />
                  </button>
                </label>
                <p className="form-hint">
                  Include timestamps in the transcript output.
                  {settings.stt.sttProvider === 'qwen-edge' && ' Qwen3-ASR uses the companion ForcedAligner model for timestamps.'}
                </p>
              </div>

              {settings.stt.sttProvider !== 'qwen-edge' && (
                <div className="form-group">
                  <label className="form-label" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                    <span>Speaker Diarization</span>
                    <button
                      className={`toggle-switch ${settings.stt.sttDiarize ? 'active' : ''}`}
                      onClick={() =>
                        setSettings({
                          ...settings,
                          stt: { ...settings.stt, sttDiarize: !settings.stt.sttDiarize },
                        })
                      }
                    >
                      <span className="toggle-slider" />
                    </button>
                  </label>
                  <p className="form-hint">
                    Identify and label different speakers. Available with Mistral Cloud (batch mode).
                  </p>
                </div>
              )}

              <div className="form-group">
                <label className="form-label">Language</label>
                <select
                  className="form-select"
                  value={settings.stt.sttLanguage}
                  onChange={(e) =>
                    setSettings({
                      ...settings,
                      stt: { ...settings.stt, sttLanguage: e.target.value },
                    })
                  }
                >
                  <option value="">Auto-detect</option>
                  <option value="en">English</option>
                  <option value="de">German</option>
                  <option value="fr">French</option>
                  <option value="es">Spanish</option>
                  <option value="it">Italian</option>
                  <option value="pt">Portuguese</option>
                  <option value="nl">Dutch</option>
                  <option value="ru">Russian</option>
                  <option value="zh">Chinese (Mandarin)</option>
                  <option value="ja">Japanese</option>
                  <option value="ko">Korean</option>
                  <option value="ar">Arabic</option>
                  <option value="hi">Hindi</option>
                  {settings.stt.sttProvider === 'qwen-edge' && (
                    <>
                      <option value="th">Thai</option>
                      <option value="vi">Vietnamese</option>
                      <option value="id">Indonesian</option>
                      <option value="ms">Malay</option>
                      <option value="tr">Turkish</option>
                      <option value="pl">Polish</option>
                      <option value="uk">Ukrainian</option>
                      <option value="cs">Czech</option>
                      <option value="sv">Swedish</option>
                      <option value="da">Danish</option>
                      <option value="fi">Finnish</option>
                      <option value="no">Norwegian</option>
                      <option value="el">Greek</option>
                      <option value="he">Hebrew</option>
                      <option value="hu">Hungarian</option>
                      <option value="ro">Romanian</option>
                      <option value="bg">Bulgarian</option>
                    </>
                  )}
                </select>
                <p className="form-hint">
                  {settings.stt.sttProvider === 'qwen-edge'
                    ? 'Qwen3-ASR supports 52 languages including 22 Chinese dialects.'
                    : 'Mistral Voxtral supports 13 languages.'}
                </p>
              </div>

              <div className="form-group">
                <button
                  className="btn btn-secondary"
                  onClick={async () => {
                    setSttTestResult(null);
                    const result = await window.api.stt.checkAvailable();
                    setSttTestResult(result.available ? 'success' : 'error');
                  }}
                  style={{ width: '100%' }}
                >
                  Test Transcription Connection
                </button>
                {sttTestResult && (
                  <p
                    className="form-hint"
                    style={{
                      color: sttTestResult === 'success' ? 'var(--success-color)' : 'var(--error-color)',
                      marginTop: '8px',
                    }}
                  >
                    {sttTestResult === 'success'
                      ? 'Transcription service is available!'
                      : 'Cannot reach transcription service. Check your settings.'}
                  </p>
                )}
              </div>

              {/* Model comparison note */}
              <div className="form-group">
                <div style={{ background: 'var(--bg-tertiary)', padding: '12px', borderRadius: '6px', fontSize: '11px', color: 'var(--text-muted)', lineHeight: 1.6 }}>
                  <strong style={{ color: 'var(--text-secondary)' }}>Edge Model Comparison</strong><br />
                  <strong>Mistral Voxtral Mini 3B:</strong> ~3B params, ~5GB (FP8), 13 langs, timestamps + diarization, needs GPU<br />
                  <strong>Qwen3-ASR-0.6B:</strong> ~0.6B params, ~1.3GB (Q8), 52 langs, timestamps via ForcedAligner, runs on CPU<br />
                  <br />
                  Voxtral is more accurate with richer features (diarization, context biasing).
                  Qwen3-ASR is 5x smaller and runs on any hardware without a GPU.
                </div>
              </div>
            </>
          )}

          {activeTab === 'editor' && (
            <>
              <div className="form-group">
                <label className="form-label" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <span>Enable Spellcheck</span>
                  <button
                    className={`toggle-switch ${settings.spellcheckEnabled ? 'active' : ''}`}
                    onClick={() => setSettings({ ...settings, spellcheckEnabled: !settings.spellcheckEnabled })}
                  >
                    <span className="toggle-slider" />
                  </button>
                </label>
                <p className="form-hint">
                  Underlines misspelled words. Right-click to see suggestions.
                </p>
              </div>

              {settings.spellcheckEnabled && (
                <div className="form-group">
                  <label className="form-label">Languages</label>
                  <p className="form-hint" style={{ marginBottom: '12px' }}>
                    Select one or more languages for spellcheck. Multiple languages can be active simultaneously.
                  </p>
                  <div className="language-grid">
                    {availableLanguages.map((lang) => {
                      const isSelected = (settings.spellcheckLanguages || []).includes(lang.code);
                      return (
                        <button
                          key={lang.code}
                          className={`language-chip ${isSelected ? 'selected' : ''}`}
                          onClick={() => toggleLanguage(lang.code)}
                        >
                          {isSelected && <Check size={14} />}
                          {lang.name}
                        </button>
                      );
                    })}
                  </div>
                  {(settings.spellcheckLanguages || []).length === 0 && (
                    <p className="form-hint" style={{ color: 'var(--warning-color)', marginTop: '8px' }}>
                      Please select at least one language for spellcheck.
                    </p>
                  )}
                </div>
              )}

              <div className="form-group" style={{ marginTop: '16px' }}>
                <p className="form-hint" style={{ background: 'var(--bg-tertiary)', padding: '12px', borderRadius: '6px' }}>
                  <strong>Note:</strong> Changes to spellcheck settings require restarting the app to take full effect.
                  Dictionaries are downloaded automatically when needed.
                </p>
              </div>
            </>
          )}
        </div>
        <div className="modal-footer">
          <button className="btn btn-secondary" onClick={onClose}>
            Cancel
          </button>
          <button className="btn btn-primary" onClick={handleSave} disabled={isSaving}>
            {isSaving ? 'Saving...' : 'Save Settings'}
          </button>
        </div>
      </div>
    </div>
  );
}

export default SettingsModal;
