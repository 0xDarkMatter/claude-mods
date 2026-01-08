import { readFile, writeFile, mkdir } from 'fs/promises';
import { existsSync } from 'fs';
import { dirname } from 'path';

export interface CanvasMeta {
  version: string;
  contentType: 'email' | 'message' | 'doc';
  mode: 'view' | 'edit';
  claudeLastWrite: string | null;
  userLastEdit: string | null;
  title?: string;
}

const DEFAULT_META: CanvasMeta = {
  version: '1.0',
  contentType: 'doc',
  mode: 'view',
  claudeLastWrite: null,
  userLastEdit: null
};

/**
 * Read meta.json from canvas directory
 */
export async function readMeta(metaPath: string): Promise<CanvasMeta> {
  try {
    if (!existsSync(metaPath)) {
      return DEFAULT_META;
    }
    const data = await readFile(metaPath, 'utf-8');
    return { ...DEFAULT_META, ...JSON.parse(data) };
  } catch {
    return DEFAULT_META;
  }
}

/**
 * Write meta.json to canvas directory
 */
export async function writeMeta(metaPath: string, meta: Partial<CanvasMeta>): Promise<void> {
  const dir = dirname(metaPath);
  if (!existsSync(dir)) {
    await mkdir(dir, { recursive: true });
  }

  const existing = await readMeta(metaPath);
  const updated: CanvasMeta = {
    ...existing,
    ...meta
  };

  await writeFile(metaPath, JSON.stringify(updated, null, 2), 'utf-8');
}

/**
 * Read content from canvas content file
 */
export async function readContent(contentPath: string): Promise<string | null> {
  try {
    if (!existsSync(contentPath)) {
      return null;
    }
    return await readFile(contentPath, 'utf-8');
  } catch {
    return null;
  }
}

/**
 * Write content to canvas content file
 */
export async function writeContent(contentPath: string, content: string): Promise<void> {
  const dir = dirname(contentPath);
  if (!existsSync(dir)) {
    await mkdir(dir, { recursive: true });
  }
  await writeFile(contentPath, content, 'utf-8');
}

/**
 * Initialize canvas directory with default files
 */
export async function initCanvas(
  canvasDir: string,
  contentType: CanvasMeta['contentType'] = 'doc'
): Promise<void> {
  const contentPath = `${canvasDir}/content.md`;
  const metaPath = `${canvasDir}/meta.json`;

  // Ensure directory exists
  if (!existsSync(canvasDir)) {
    await mkdir(canvasDir, { recursive: true });
  }

  // Create meta file
  await writeMeta(metaPath, {
    contentType,
    claudeLastWrite: new Date().toISOString()
  });

  // Create empty content file if it doesn't exist
  if (!existsSync(contentPath)) {
    await writeContent(contentPath, '');
  }
}
