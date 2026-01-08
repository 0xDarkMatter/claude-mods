import { useMemo } from 'react';
import { marked } from 'marked';
import { markedTerminal } from 'marked-terminal';
import chalk from 'chalk';

// Configure marked with terminal renderer
// Using colors that work on both light and dark backgrounds
marked.use(
  markedTerminal({
    // Colors for different elements - avoiding white/black for cross-theme support
    code: chalk.cyan,
    blockquote: chalk.gray.italic,
    html: chalk.gray,
    heading: chalk.bold.blue,
    firstHeading: chalk.bold.blue.underline,
    hr: chalk.gray,
    listitem: chalk.reset,  // Use default terminal color
    list: (body: string) => body,
    table: chalk.reset,
    paragraph: chalk.reset, // Use default terminal color
    strong: chalk.bold,
    em: chalk.italic,
    codespan: chalk.magenta,
    del: chalk.strikethrough.gray,
    link: chalk.blue.underline,
    href: chalk.blue.underline,

    // Table rendering
    tableOptions: {
      chars: {
        top: '-',
        'top-mid': '+',
        'top-left': '+',
        'top-right': '+',
        bottom: '-',
        'bottom-mid': '+',
        'bottom-left': '+',
        'bottom-right': '+',
        left: '|',
        'left-mid': '+',
        mid: '-',
        'mid-mid': '+',
        right: '|',
        'right-mid': '+',
        middle: '|'
      }
    },

    // Misc settings
    reflowText: true,
    width: 80,
    showSectionPrefix: false,
    tab: 2
  })
);

export function useMarkdown(content: string): string {
  return useMemo(() => {
    if (!content) return '';

    try {
      // Parse markdown to terminal-formatted string
      const rendered = marked.parse(content);
      // marked returns Promise in some configs, but sync with markedTerminal
      if (typeof rendered === 'string') {
        // Ensure proper spacing after headings
        // ANSI underline is \x1B[4m, reset includes \x1B[0m or \x1B[24m
        const lines = rendered.trim().split('\n');
        const result: string[] = [];

        for (let i = 0; i < lines.length; i++) {
          result.push(lines[i]);

          // If this line contains underline codes (h1) or bold (other headings)
          // and next line exists and is not empty, add a blank line
          const hasUnderline = lines[i].includes('\x1B[4m');
          const nextLine = lines[i + 1];
          if (hasUnderline && nextLine !== undefined && nextLine.trim() !== '') {
            result.push('');
          }
        }

        return result.join('\n');
      }
      return content; // Fallback to raw content
    } catch (err) {
      console.error('Markdown parse error:', err);
      return content; // Return raw content on error
    }
  }, [content]);
}
