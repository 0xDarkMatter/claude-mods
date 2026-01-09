#!/usr/bin/env node
import React from 'react';
import fs from 'fs';
import path from 'path';
import { render } from 'ink';
import meow from 'meow';
import { App } from './app.js';

const cli = meow(`
  Usage
    $ canvas [options]

  Options
    --watch, -w       Watch directory (default: .claude/canvas)
    --file, -f        Specific file to watch
    --mouse, -m       Enable mouse wheel scrolling (default: off)
    --help            Show this help
    --version         Show version

  Examples
    $ canvas                     # Just run it - defaults work
    $ canvas --file ./draft.md   # Watch specific file

  Controls
    ↑↓ / Mouse wheel    Scroll content
    g / G               Top / bottom
    Tab                 Open file selector
    e                   Edit in external editor
    m                   Toggle mouse capture
    q                   Quit

  Terminal Setup
    Warp:     Ctrl+Shift+D to split, run 'canvas' in new pane
    tmux:     tmux split-window -h 'canvas'
    iTerm2:   Cmd+D to split, run 'canvas' in new pane
`, {
  importMeta: import.meta,
  flags: {
    watch: {
      type: 'string',
      shortFlag: 'w',
      default: '.claude/canvas'
    },
    file: {
      type: 'string',
      shortFlag: 'f'
    },
    mouse: {
      type: 'boolean',
      shortFlag: 'm',
      default: false
    }
  }
});

// Find canvas directory by searching up from CWD
function findCanvasDir(startDir: string = process.cwd()): string | null {
  let current = startDir;
  const root = path.parse(current).root;

  while (current !== root) {
    const candidate = path.join(current, '.claude', 'canvas');
    if (fs.existsSync(candidate)) {
      return candidate;
    }
    current = path.dirname(current);
  }
  return null;
}

// Determine watch directory - find it automatically or use explicit path
function getWatchDir(explicitPath: string): string {
  // If user specified absolute path, use it
  if (path.isAbsolute(explicitPath)) {
    return explicitPath;
  }

  // Try to find .claude/canvas by searching up
  const found = findCanvasDir();
  if (found) {
    return found;
  }

  // Fall back to relative path from CWD
  return path.resolve(explicitPath);
}

// Determine initial file to watch
function getInitialFile(watchDir: string, specificFile?: string): string {
  if (specificFile) return path.resolve(specificFile);

  // Check drafts directory first
  const draftsDir = path.join(watchDir, 'drafts');
  try {
    if (fs.existsSync(draftsDir)) {
      const files = fs.readdirSync(draftsDir)
        .filter(f => f.endsWith('.md') || f.endsWith('.txt'))
        .sort((a, b) => {
          const statA = fs.statSync(path.join(draftsDir, a));
          const statB = fs.statSync(path.join(draftsDir, b));
          return statB.mtime.getTime() - statA.mtime.getTime();
        });
      if (files.length > 0) {
        return path.join(draftsDir, files[0]);
      }
    }
  } catch {
    // Fall through to default
  }

  // Fallback to content.md in watch dir
  return path.join(watchDir, 'content.md');
}

const watchDir = getWatchDir(cli.flags.watch);
const watchPath = getInitialFile(watchDir, cli.flags.file);

render(<App watchPath={watchPath} watchDir={watchDir} enableMouse={cli.flags.mouse} />);
