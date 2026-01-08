#!/usr/bin/env node
import React from 'react';
import { render } from 'ink';
import meow from 'meow';
import { App } from './app.js';

const cli = meow(`
  Usage
    $ canvas-tui [options]

  Options
    --watch, -w       Watch directory for changes (default: .claude/canvas)
    --file, -f        Specific file to watch
    --no-mouse        Disable mouse wheel scrolling
    --help            Show this help message
    --version         Show version

  Examples
    $ canvas-tui --watch
    $ canvas-tui --file ./draft.md
    $ canvas-tui --watch --no-mouse

  Controls
    Arrow keys / Mouse wheel    Scroll content
    g / G                       Go to top / bottom
    q / Ctrl+C                  Quit
    r                           Refresh

  Terminal Setup
    Warp:     Ctrl+Shift+D to split, run canvas-tui in new pane
    tmux:     tmux split-window -h 'canvas-tui --watch'
    iTerm2:   Cmd+D to split, run canvas-tui in new pane
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
    noMouse: {
      type: 'boolean',
      default: false
    }
  }
});

const watchPath = cli.flags.file || `${cli.flags.watch}/content.md`;

render(<App watchPath={watchPath} watchDir={cli.flags.watch} enableMouse={!cli.flags.noMouse} />);
