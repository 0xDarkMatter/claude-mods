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

export const App: React.FC<AppProps> = ({ watchPath, watchDir, enableMouse = false }) => {
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
  useLayoutEffect(() => {
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

    // Get filename from path
    const fileName = currentFilePath.split(/[/\\]/).pop() || 'Unknown';

    // Content lines (without border/padding - we'll add those)
    const contentLines: string[] = [
      '\x1B[1mFile Metadata\x1B[0m',
      '',
      `Filename:   ${fileName}`,
      `Created:    ${created}`,
      `Modified:   ${modified}`,
      `Size:       ${fileSize}`,
      '',
      `Lines:      ${lineCount.toLocaleString()}`,
      `Words:      ${wordCount.toLocaleString()}`,
      `Characters: ${charCount.toLocaleString()}`,
      '',
      '\x1B[2m[i] Close\x1B[0m',
    ];

    // Calculate inner content width
    const innerWidth = Math.max(...contentLines.map(l => l.replace(/\x1B\[[0-9;]*m/g, '').length));

    // Build the full panel with border and padding
    // Horizontal: 2 space padding, Vertical: 1 space padding
    const boxWidth = innerWidth + 6; // 2 space padding each side inside border, +2 for border chars
    const totalWidth = boxWidth + 2; // +2 for outer spacing

    const panelLines: string[] = [];

    // Outer top padding
    panelLines.push(' '.repeat(totalWidth));

    // Top border: space + ┌ + ─ repeated + ┐ + space
    panelLines.push(` ┌${'─'.repeat(boxWidth - 2)}┐ `);

    // Inner top padding row (1 line vertical padding)
    panelLines.push(` │${' '.repeat(boxWidth - 2)}│ `);

    // Content rows with 2-space horizontal padding
    contentLines.forEach(line => {
      const plainLen = line.replace(/\x1B\[[0-9;]*m/g, '').length;
      const rightPad = innerWidth - plainLen;
      panelLines.push(` │  ${line}${' '.repeat(rightPad)}  │ `);
    });

    // Inner bottom padding row (1 line vertical padding)
    panelLines.push(` │${' '.repeat(boxWidth - 2)}│ `);

    // Bottom border
    panelLines.push(` └${'─'.repeat(boxWidth - 2)}┘ `);

    // Outer bottom padding
    panelLines.push(' '.repeat(totalWidth));

    // Center the panel
    const panelHeight = panelLines.length;
    const startRow = Math.floor((rows - panelHeight) / 2);
    const startCol = Math.floor((cols - totalWidth) / 2);

    // Guard against re-entry when we write our own overlay
    let isRenderingOverlay = false;

    // Function to render the overlay
    const renderOverlay = () => {
      if (isRenderingOverlay) return;
      isRenderingOverlay = true;

      let output = '\x1B[s'; // Save cursor
      panelLines.forEach((line, idx) => {
        const row = startRow + idx;
        output += `\x1B[${row};${startCol}H${line}`;
      });
      output += '\x1B[u'; // Restore cursor
      originalWrite.call(process.stdout, output);

      isRenderingOverlay = false;
    };

    // Intercept stdout.write to repaint overlay after Ink renders
    const originalWrite = process.stdout.write;
    process.stdout.write = function(chunk: any, encoding?: any, callback?: any) {
      const result = originalWrite.call(process.stdout, chunk, encoding, callback);
      if (!isRenderingOverlay) {
        setImmediate(renderOverlay);
      }
      return result;
    } as typeof process.stdout.write;

    // Initial render
    renderOverlay();

    // Cleanup: restore stdout.write and clear the panel area
    return () => {
      process.stdout.write = originalWrite;

      let clear = '\x1B[s';
      panelLines.forEach((_, idx) => {
        const row = startRow + idx;
        clear += `\x1B[${row};${startCol}H${' '.repeat(totalWidth)}`;
      });
      clear += '\x1B[u';
      originalWrite.call(process.stdout, clear);
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

  // Format timestamp: DD.MM.YYYY HH:MMam (no seconds)
  const formatTimestamp = (date: Date) => {
    const day = String(date.getDate()).padStart(2, '0');
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const year = date.getFullYear();
    let hours = date.getHours();
    const ampm = hours >= 12 ? 'pm' : 'am';
    hours = hours % 12 || 12;
    const minutes = String(date.getMinutes()).padStart(2, '0');
    return `${day}.${month}.${year} ${hours}:${minutes}${ampm}`;
  };

  const timestampStr = lastUpdate ? formatTimestamp(lastUpdate) : null;

  // Position indicator: Pos: [001-056/168]
  const pad3 = (n: number) => String(n).padStart(3, '0');
  const positionStr = totalLines > 0
    ? `Pos: [${pad3(scrollOffset + 1)}-${pad3(Math.min(scrollOffset + contentHeight, totalLines))}/${totalLines}]`
    : null;

  const hints = isEditing
    ? 'Editing...'
    : isInfoOpen
    ? '[i] Close'
    : isDropdownOpen
    ? '[Tab] Close [↑↓] Nav [Enter] Open'
    : '[Tab] Files [i] Info [e] Edit [m] Mouse [q] Quit';

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
        timestamp={timestampStr}
        position={positionStr}
        hints={hints}
        width={cols}
      />
    </Box>
  );
};
