import { useState, useEffect } from 'react';
import { watch } from 'chokidar';
import { readFile } from 'fs/promises';
import { existsSync } from 'fs';

interface FileWatcherResult {
  content: string | null;
  error: string | null;
  isWatching: boolean;
}

export function useFileWatcher(filePath: string): FileWatcherResult {
  const [content, setContent] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isWatching, setIsWatching] = useState(false);

  useEffect(() => {
    let watcher: ReturnType<typeof watch> | null = null;

    const readContent = async () => {
      try {
        if (existsSync(filePath)) {
          const data = await readFile(filePath, 'utf-8');
          setContent(data);
          setError(null);
        }
      } catch (err) {
        setError(`Failed to read file: ${err instanceof Error ? err.message : String(err)}`);
      }
    };

    const startWatching = () => {
      // Initial read
      readContent();

      // Set up watcher
      watcher = watch(filePath, {
        persistent: true,
        ignoreInitial: false,
        awaitWriteFinish: {
          stabilityThreshold: 100,
          pollInterval: 50
        }
      });

      watcher.on('add', () => {
        readContent();
        setIsWatching(true);
      });

      watcher.on('change', () => {
        readContent();
      });

      watcher.on('unlink', () => {
        setContent(null);
        setError('File was deleted');
      });

      watcher.on('error', (err: unknown) => {
        const message = err instanceof Error ? err.message : String(err);
        setError(`Watcher error: ${message}`);
      });

      setIsWatching(true);
    };

    startWatching();

    return () => {
      if (watcher) {
        watcher.close();
      }
    };
  }, [filePath]);

  return { content, error, isWatching };
}
