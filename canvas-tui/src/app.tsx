import React, { useState, useEffect, useLayoutEffect } from 'react';
import { Box, Text, useApp, useInput, useStdout } from 'ink';
import { Header } from './components/Header.js';
import { MarkdownView } from './components/MarkdownView.js';
import { StatusBar } from './components/StatusBar.js';
import { useFileWatcher } from './hooks/useFileWatcher.js';
import { readMeta, type CanvasMeta } from './lib/ipc.js';

interface AppProps {
  watchPath: string;
  watchDir: string;
  enableMouse?: boolean;
}

// ANSI escape sequences for mouse support
const ENABLE_MOUSE = '\x1B[?1000h\x1B[?1002h\x1B[?1006h';
const DISABLE_MOUSE = '\x1B[?1000l\x1B[?1002l\x1B[?1006l';

export const App: React.FC<AppProps> = ({ watchPath, watchDir, enableMouse = true }) => {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [content, setContent] = useState<string>('');
  const [meta, setMeta] = useState<CanvasMeta | null>(null);
  const [syncStatus, setSyncStatus] = useState<'waiting' | 'synced' | 'watching'>('waiting');
  const [lastUpdate, setLastUpdate] = useState<Date | null>(null);
  const [scrollOffset, setScrollOffset] = useState(0);
  const [totalLines, setTotalLines] = useState(0);

  // Terminal dimensions
  const rows = stdout?.rows || 24;
  const cols = stdout?.columns || 80;
  const contentHeight = rows - 4; // Header (2) + Footer (2)

  // File watcher
  const { content: watchedContent, error } = useFileWatcher(watchPath);

  // Enable mouse tracking
  useLayoutEffect(() => {
    if (enableMouse) {
      process.stdout.write(ENABLE_MOUSE);

      // Listen for mouse events on stdin
      const handleData = (data: Buffer) => {
        const str = data.toString();

        // SGR mouse format: \x1B[<button;x;yM or \x1B[<button;x;ym
        // Button 64 = scroll up, Button 65 = scroll down
        const sgrMatch = str.match(/\x1B\[<(\d+);(\d+);(\d+)([Mm])/);
        if (sgrMatch) {
          const button = parseInt(sgrMatch[1], 10);
          if (button === 64) {
            // Scroll up
            setScrollOffset(prev => Math.max(0, prev - 3));
          } else if (button === 65) {
            // Scroll down
            setScrollOffset(prev => Math.min(Math.max(0, totalLines - contentHeight), prev + 3));
          }
        }
      };

      process.stdin.on('data', handleData);

      return () => {
        process.stdout.write(DISABLE_MOUSE);
        process.stdin.off('data', handleData);
      };
    }
  }, [enableMouse, totalLines, contentHeight]);

  // Update content when file changes
  useEffect(() => {
    if (watchedContent !== null) {
      setContent(watchedContent);
      setSyncStatus('synced');
      setLastUpdate(new Date());
      setScrollOffset(0);

      const metaPath = watchDir + '/meta.json';
      readMeta(metaPath).then(setMeta).catch(() => {});
    }
  }, [watchedContent, watchDir]);

  // Keyboard input
  useInput((input, key) => {
    if (input === 'q' || (key.ctrl && input === 'c')) {
      if (enableMouse) {
        process.stdout.write(DISABLE_MOUSE);
      }
      exit();
    }

    if (key.upArrow) {
      setScrollOffset(prev => Math.max(0, prev - 1));
    }
    if (key.downArrow) {
      setScrollOffset(prev => Math.min(Math.max(0, totalLines - contentHeight), prev + 1));
    }
    if (key.pageUp) {
      setScrollOffset(prev => Math.max(0, prev - contentHeight));
    }
    if (key.pageDown) {
      setScrollOffset(prev => Math.min(Math.max(0, totalLines - contentHeight), prev + contentHeight));
    }
    if (input === 'g') {
      setScrollOffset(0);
    }
    if (input === 'G') {
      setScrollOffset(Math.max(0, totalLines - contentHeight));
    }
    if (input === 'r') {
      setSyncStatus('watching');
    }
  });

  // Status message
  const statusMessage = error
    ? `Error: ${error}`
    : syncStatus === 'waiting'
    ? `Waiting for ${watchPath}...`
    : `Updated: ${lastUpdate?.toLocaleTimeString() || ''}`;

  const scrollHint = totalLines > contentHeight
    ? ` | ${scrollOffset + 1}-${Math.min(scrollOffset + contentHeight, totalLines)}/${totalLines}`
    : '';

  const hints = enableMouse
    ? `q: quit | scroll: arrows/mouse${scrollHint}`
    : `q: quit | scroll: arrows${scrollHint}`;

  return (
    <Box flexDirection="column" height={rows}>
      <Header title="Canvas" contentType={meta?.contentType || 'doc'} width={cols} />

      <Box flexGrow={1} flexDirection="column" overflow="hidden">
        {content ? (
          <MarkdownView
            content={content}
            scrollOffset={scrollOffset}
            maxHeight={contentHeight}
            onLineCount={setTotalLines}
          />
        ) : (
          <Box padding={1}>
            <Text color="gray">
              {error ? (
                <Text color="red">{error}</Text>
              ) : (
                `Watching ${watchPath}...\n\nUse /canvas write in Claude Code to send content.`
              )}
            </Text>
          </Box>
        )}
      </Box>

      <StatusBar
        status={syncStatus}
        message={statusMessage}
        hints={hints}
        width={cols}
      />
    </Box>
  );
};
