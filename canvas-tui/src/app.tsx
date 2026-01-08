import React, { useState, useEffect } from 'react';
import { Box, Text, useApp, useInput, useStdout } from 'ink';
import { Header } from './components/Header.js';
import { MarkdownView } from './components/MarkdownView.js';
import { StatusBar } from './components/StatusBar.js';
import { useFileWatcher } from './hooks/useFileWatcher.js';
import { readMeta, type CanvasMeta } from './lib/ipc.js';

interface AppProps {
  watchPath: string;
  watchDir: string;
}

export const App: React.FC<AppProps> = ({ watchPath, watchDir }) => {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [content, setContent] = useState<string>('');
  const [meta, setMeta] = useState<CanvasMeta | null>(null);
  const [syncStatus, setSyncStatus] = useState<'waiting' | 'synced' | 'watching'>('waiting');
  const [lastUpdate, setLastUpdate] = useState<Date | null>(null);
  const [scrollOffset, setScrollOffset] = useState(0);

  // Terminal dimensions
  const rows = stdout?.rows || 24;
  const cols = stdout?.columns || 80;

  // File watcher
  const { content: watchedContent, error } = useFileWatcher(watchPath);

  // Update content when file changes
  useEffect(() => {
    if (watchedContent !== null) {
      setContent(watchedContent);
      setSyncStatus('synced');
      setLastUpdate(new Date());

      // Also read meta file
      const metaPath = watchDir + '/meta.json';
      readMeta(metaPath).then(setMeta).catch(() => {});
    }
  }, [watchedContent, watchDir]);

  // Keyboard input
  useInput((input, key) => {
    if (input === 'q' || (key.ctrl && input === 'c')) {
      exit();
    }
    if (key.upArrow) {
      setScrollOffset(prev => Math.max(0, prev - 1));
    }
    if (key.downArrow) {
      setScrollOffset(prev => prev + 1);
    }
    if (input === 'g') {
      setScrollOffset(0); // Go to top
    }
    if (input === 'G') {
      // Go to bottom - handled in MarkdownView
      setScrollOffset(999999);
    }
    if (input === 'r') {
      // Force refresh - re-read file
      setSyncStatus('watching');
    }
  });

  // Determine status message
  let statusMessage = '';
  if (error) {
    statusMessage = `Error: ${error}`;
  } else if (syncStatus === 'waiting') {
    statusMessage = `Waiting for content at ${watchPath}...`;
  } else if (syncStatus === 'synced' && lastUpdate) {
    statusMessage = `Last updated: ${lastUpdate.toLocaleTimeString()}`;
  }

  return (
    <Box flexDirection="column" height={rows}>
      <Header
        title="Canvas"
        contentType={meta?.contentType || 'doc'}
        width={cols}
      />

      <Box flexGrow={1} flexDirection="column" overflow="hidden">
        {content ? (
          <MarkdownView
            content={content}
            scrollOffset={scrollOffset}
            maxHeight={rows - 4}
          />
        ) : (
          <Box padding={1}>
            <Text color="gray">
              {error ? (
                <Text color="red">{error}</Text>
              ) : (
                `Watching ${watchPath} for changes...\n\nUse /canvas write in Claude Code to send content here.`
              )}
            </Text>
          </Box>
        )}
      </Box>

      <StatusBar
        status={syncStatus}
        message={statusMessage}
        hints="q: quit | arrows: scroll | r: refresh"
        width={cols}
      />
    </Box>
  );
};
