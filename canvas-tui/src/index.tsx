#!/usr/bin/env node
import React from 'react';
import { render } from 'ink';
import meow from 'meow';
import { App } from './app.js';

const cli = meow(`
  Usage
    $ canvas [options]

  Options
    --watch, -w       Watch directory (default: .claude/canvas)
    --file, -f        Specific file to watch
    --no-mouse        Disable mouse wheel scrolling
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
    noMouse: {
      type: 'boolean',
      default: false
    }
  }
});

const watchPath = cli.flags.file || `${cli.flags.watch}/content.md`;

render(<App watchPath={watchPath} watchDir={cli.flags.watch} enableMouse={!cli.flags.noMouse} />);
