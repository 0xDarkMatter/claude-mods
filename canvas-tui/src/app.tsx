import React, { useState, useEffect, useLayoutEffect } from 'react';
import { Box, Text, useApp, useInput, useStdout } from 'ink';
import fs from 'fs';
import { Header } from './components/Header.js';
import { MarkdownView } from './components/MarkdownView.js';
import { StatusBar } from './components/StatusBar.js';
import { useFileWatcher } from './hooks/useFileWatcher.js';
import { useDirectoryFiles } from './hooks/useDirectoryFiles.js';
import { readMeta, type CanvasMeta } from './lib/ipc.js';
import { editInExternalEditor } from './lib/editor.js';

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
  const [mouseEnabled, setMouseEnabled] = useState(enableMouse);
  const [isEditing, setIsEditing] = useState(false);

  // File selector state
  const [currentFilePath, setCurrentFilePath] = useState(watchPath);
  const [isDropdownOpen, setIsDropdownOpen] = useState(false);
  const [isDropdownFocused, setIsDropdownFocused] = useState(false);
  const [selectedFileIndex, setSelectedFileIndex] = useState(0);

  // Info overlay state
  const [isInfoOpen, setIsInfoOpen] = useState(false);

  // Terminal dimensions
  const rows = stdout?.rows || 24;
  const cols = stdout?.columns || 80;
  const contentHeight = rows - 4; // Header (2) + Footer (2)

  // Get files in directory
  const files = useDirectoryFiles(watchDir);

  // File watcher - watch the current file
  const { content: watchedContent, error } = useFileWatcher(currentFilePath);

  // Enable mouse tracking
  useLayoutEffect(() => {
    if (mouseEnabled) {
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
  }, [mouseEnabled, totalLines, contentHeight]);

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

  // Info overlay using ANSI escape codes
  useEffect(() => {
    if (!isInfoOpen || !stdout) return;

    // Get file stats
    let stats: fs.Stats | null = null;
    try {
      stats = fs.statSync(currentFilePath);
    } catch {
      // File may not exist yet
    }

    // Calculate content stats
    const lineCount = content ? content.split('\n').length : 0;
    const wordCount = content ? content.split(/\s+/).filter(w => w.length > 0).length : 0;
    const charCount = content ? content.length : 0;

    // Format dates
    const formatDate = (date: Date) => {
      return `${date.toLocaleDateString()} ${date.toLocaleTimeString()}`;
    };

    const created = stats ? formatDate(stats.birthtime) : 'Unknown';
    const modified = stats ? formatDate(stats.mtime) : 'Unknown';
    const fileSize = stats ? `${stats.size} bytes` : 'Unknown';

    // Build info panel content
    const lines: string[] = [
      '\x1B[1m  File Info  \x1B[0m',
      '',
      `  Created:    ${created}`,
      `  Modified:   ${modified}`,
      `  Size:       ${fileSize}`,
      '',
      `  Lines:      ${lineCount.toLocaleString()}`,
      `  Words:      ${wordCount.toLocaleString()}`,
      `  Characters: ${charCount.toLocaleString()}`,
      '',
      '\x1B[2m  Press [i] to close  \x1B[0m',
    ];

    // Calculate panel dimensions
    const maxLen = Math.max(...lines.map(l => l.replace(/\x1B\[[0-9;]*m/g, '').length)) + 2;
    const panelHeight = lines.length;

    // Center the panel
    const startRow = Math.floor((rows - panelHeight) / 2);
    const startCol = Math.floor((cols - maxLen) / 2);

    // Render overlay
    let output = '\x1B[s'; // Save cursor

    lines.forEach((line, idx) => {
      const row = startRow + idx;
      const plainLen = line.replace(/\x1B\[[0-9;]*m/g, '').length;
      const padding = maxLen - plainLen;
      // Dim background for panel
      output += `\x1B[${row};${startCol}H\x1B[48;5;236m${line}${' '.repeat(padding)}\x1B[0m`;
    });

    output += '\x1B[u'; // Restore cursor
    process.stdout.write(output);

    // Cleanup: clear the info panel area
    return () => {
      let clear = '\x1B[s';
      lines.forEach((_, idx) => {
        const row = startRow + idx;
        clear += `\x1B[${row};${startCol}H${' '.repeat(maxLen)}`;
      });
      clear += '\x1B[u';
      process.stdout.write(clear);
    };
  }, [isInfoOpen, currentFilePath, content, stdout, rows, cols]);

  // Keyboard input
  useInput((input, key) => {
    // Quit
    if (input === 'q' || (key.ctrl && input === 'c')) {
      if (mouseEnabled) {
        process.stdout.write(DISABLE_MOUSE);
      }
      exit();
    }

    // Other files (excluding current) for dropdown navigation
    const otherFiles = files.filter(f => f.path !== currentFilePath);

    // Tab - toggle file selector focus
    if (key.tab) {
      if (isDropdownFocused) {
        // Close dropdown and unfocus
        setIsDropdownFocused(false);
        setIsDropdownOpen(false);
      } else {
        // Focus and open dropdown
        setIsDropdownFocused(true);
        setIsDropdownOpen(true);
        // Start at first file
        setSelectedFileIndex(0);
      }
      return;
    }

    // Escape - close dropdown or info
    if (key.escape) {
      if (isInfoOpen) {
        setIsInfoOpen(false);
        return;
      }
      if (isDropdownOpen) {
        setIsDropdownOpen(false);
        setIsDropdownFocused(false);
        return;
      }
    }

    // When dropdown is open, arrow keys navigate files
    if (isDropdownOpen) {
      if (key.upArrow) {
        setSelectedFileIndex(prev => Math.max(0, prev - 1));
        return;
      }
      if (key.downArrow) {
        setSelectedFileIndex(prev => Math.min(otherFiles.length - 1, prev + 1));
        return;
      }
      if (key.return && otherFiles[selectedFileIndex]) {
        // Select file and close dropdown
        setCurrentFilePath(otherFiles[selectedFileIndex].path);
        setIsDropdownOpen(false);
        setIsDropdownFocused(false);
        setScrollOffset(0);
        return;
      }
    }

    // Scrolling (only when dropdown and info are closed)
    if (!isInfoOpen) {
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

      // Home/End and vim-style navigation
      if (input === 'g' || key.meta && key.upArrow) {
        setScrollOffset(0);
      }
      if (input === 'G' || key.meta && key.downArrow) {
        setScrollOffset(Math.max(0, totalLines - contentHeight));
      }
    }

    // Refresh
    if (input === 'r') {
      setSyncStatus('watching');
    }

    // Toggle mouse capture
    if (input === 'm') {
      setMouseEnabled(prev => {
        const newValue = !prev;
        if (newValue) {
          process.stdout.write(ENABLE_MOUSE);
        } else {
          process.stdout.write(DISABLE_MOUSE);
        }
        return newValue;
      });
    }

    // Toggle info overlay
    if (input === 'i' && !isEditing && !isDropdownOpen) {
      setIsInfoOpen(prev => !prev);
    }

    // Edit in external editor
    if (input === 'e' && !isEditing && content) {
      setIsEditing(true);
      // Disable mouse while editing
      if (mouseEnabled) {
        process.stdout.write(DISABLE_MOUSE);
      }
      editInExternalEditor(currentFilePath)
        .then(() => {
          setIsEditing(false);
          // Re-enable mouse if it was on
          if (mouseEnabled) {
            process.stdout.write(ENABLE_MOUSE);
          }
        })
        .catch(() => {
          setIsEditing(false);
          if (mouseEnabled) {
            process.stdout.write(ENABLE_MOUSE);
          }
        });
    }
  });

  // Status info
  const currentFileName = currentFilePath.split(/[/\\]/).pop() || 'file';
  const timestampStr = lastUpdate
    ? `${lastUpdate.toLocaleDateString()} ${lastUpdate.toLocaleTimeString()}`
    : null;

  const scrollHint = totalLines > contentHeight
    ? ` ${scrollOffset + 1}-${Math.min(scrollOffset + contentHeight, totalLines)}/${totalLines}`
    : '';

  const mouseHint = mouseEnabled ? 'on' : 'off';
  const hints = isEditing
    ? 'Editing...'
    : isInfoOpen
    ? '[i] Close'
    : isDropdownOpen
    ? '[Tab] Close [↑↓] Nav [Enter] Open'
    : `[Tab] Files [i] Info [e] Edit [m] ${mouseHint} [q] Quit${scrollHint}`;

  return (
    <Box flexDirection="column" height={rows}>
      <Header
        title="✿ CANVAS"
        width={cols}
        files={files}
        currentFile={currentFilePath}
        selectedFileIndex={selectedFileIndex}
        isDropdownOpen={isDropdownOpen}
        isDropdownFocused={isDropdownFocused}
      />

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
        filename={currentFileName}
        timestamp={timestampStr}
        hints={hints}
        width={cols}
      />
    </Box>
  );
};
