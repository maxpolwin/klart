import { safeStorage, app } from 'electron';
import * as fs from 'fs';
import * as path from 'path';

const SECRETS_FILE = path.join(app.getPath('userData'), 'secrets.enc');

interface EncryptedSecrets {
  mistralApiKey?: string; // base64-encoded encrypted value
}

/**
 * Reads the encrypted secrets file from disk.
 * Returns an empty object if the file doesn't exist or is corrupted.
 */
function readSecretsFile(): EncryptedSecrets {
  try {
    if (fs.existsSync(SECRETS_FILE)) {
      return JSON.parse(fs.readFileSync(SECRETS_FILE, 'utf-8'));
    }
  } catch (error) {
    console.error('[SecureStorage] Failed to read secrets file:', error);
  }
  return {};
}

/**
 * Writes the encrypted secrets object to disk.
 */
function writeSecretsFile(secrets: EncryptedSecrets): void {
  try {
    fs.writeFileSync(SECRETS_FILE, JSON.stringify(secrets, null, 2), { mode: 0o600 });
  } catch (error) {
    console.error('[SecureStorage] Failed to write secrets file:', error);
  }
}

/**
 * Encrypts a string using Electron's safeStorage (OS keychain-backed).
 * Returns a base64-encoded encrypted string, or the plaintext if encryption is unavailable.
 */
function encryptValue(value: string): string {
  if (!value) return '';
  if (safeStorage.isEncryptionAvailable()) {
    try {
      const encrypted = safeStorage.encryptString(value);
      return encrypted.toString('base64');
    } catch (error) {
      // e.g. macOS keychain access denied (userCanceledErr -128). Don't throw —
      // that would hang the settings save. Fall back to storing as-is (0600 file).
      console.warn('[SecureStorage] Encryption failed (keychain denied?), storing value as-is:', error);
      return value;
    }
  }
  console.warn('[SecureStorage] Encryption not available, storing value as-is');
  return value;
}

/**
 * Decrypts a base64-encoded encrypted string using Electron's safeStorage.
 * Returns the plaintext value, or the input as-is if decryption fails.
 */
function decryptValue(encoded: string): string {
  if (!encoded) return '';
  if (safeStorage.isEncryptionAvailable()) {
    try {
      const buffer = Buffer.from(encoded, 'base64');
      return safeStorage.decryptString(buffer);
    } catch (error) {
      // May be a plaintext value from before encryption was enabled,
      // or from a migration. Return as-is.
      console.warn('[SecureStorage] Decryption failed, returning raw value');
      return encoded;
    }
  }
  return encoded;
}

/**
 * Stores the Mistral API key securely.
 */
export function setMistralApiKey(apiKey: string): void {
  const secrets = readSecretsFile();
  secrets.mistralApiKey = encryptValue(apiKey);
  writeSecretsFile(secrets);
}

/**
 * Retrieves the Mistral API key, decrypting it from secure storage.
 */
export function getMistralApiKey(): string {
  const secrets = readSecretsFile();
  return decryptValue(secrets.mistralApiKey || '');
}

/**
 * Migrates a plaintext API key from settings.json into secure storage.
 * Removes the key from the provided settings object and returns the cleaned settings.
 */
export function migrateApiKeyFromSettings(settings: Record<string, unknown>): Record<string, unknown> {
  const plaintextKey = settings.mistralApiKey as string | undefined;
  if (plaintextKey && typeof plaintextKey === 'string' && plaintextKey.length > 0) {
    console.log('[SecureStorage] Migrating API key from settings.json to secure storage');
    setMistralApiKey(plaintextKey);
    // Clear the plaintext key from settings
    settings.mistralApiKey = '';
  }
  return settings;
}

/**
 * Returns whether OS-level encryption is available.
 */
export function isEncryptionAvailable(): boolean {
  return safeStorage.isEncryptionAvailable();
}
