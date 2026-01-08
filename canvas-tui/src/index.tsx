#!/usr/bin/env node
import React from 'react';
import { render } from 'ink';
import meow from 'meow';
import { App } from './app.js';

const cli = meow(`
  Usage
    $ canvas-tui [options]

  Options
    --watch, -w     Watch directory for changes (default: .claude/canvas)
    --file, -f      Specific file to watch
    --help          Show this help message
    --version       Show version

  Examples
    $ canvas-tui --watch
    $ canvas-tui --watch .claude/canvas
    $ canvas-tui --file ./draft.md
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
    }
  }
});

const watchPath = cli.flags.file || `${cli.flags.watch}/content.md`;

render(<App watchPath={watchPath} watchDir={cli.flags.watch} />);
