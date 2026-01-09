import { useMemo } from 'react';
import chalk from 'chalk';

// @ts-ignore - no types for cli-markdown
import markdown from 'cli-markdown';

export function useMarkdown(content: string, width: number = 80): string {
  return useMemo(() => {
    if (!content) return '';

    try {
      // Normalize line endings (Windows CRLF -> LF)
      const normalizedContent = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n');

      // Helper to render inline markdown formatting
      const renderInline = (text: string): string => {
        let result = text;
        // Bold
        result = result.replace(/\*\*([^*]+)\*\*/g, (_, c) => chalk.bold(c));
        // Italic
        result = result.replace(/\*([^*]+)\*/g, (_, c) => chalk.italic(c));
        // Code
        result = result.replace(/`([^`]+)`/g, (_, c) => chalk.magenta(c));
        return result;
      };

      // Process content in sections - handle numbered lists ourselves, delegate rest to cli-markdown
      const lines = normalizedContent.split('\n');
      const outputSections: string[] = [];
      let currentSection: string[] = [];
      let inNumberedList = false;
      let numberedListItems: string[] = [];

      const flushSection = () => {
        if (currentSection.length > 0) {
          // Process non-list section with cli-markdown
          const sectionContent = currentSection.join('\n');
          if (sectionContent.trim()) {
            outputSections.push(markdown(sectionContent));
          }
          currentSection = [];
        }
      };

      const flushNumberedList = () => {
        if (numberedListItems.length > 0) {
          // Render numbered list ourselves (blank line before for spacing)
          const listOutput = numberedListItems.map((item, i) =>
            `  ${i + 1}. ${renderInline(item)}`
          ).join('\n');
          outputSections.push('\n' + listOutput);
          numberedListItems = [];
        }
        inNumberedList = false;
      };

      for (const rawLine of lines) {
        const line = rawLine.trimEnd();
        const numMatch = line.match(/^(\s*)(\d+)\.\s+(.+)$/);

        if (numMatch) {
          if (!inNumberedList) {
            flushSection(); // Flush any pending non-list content
            inNumberedList = true;
          }
          numberedListItems.push(numMatch[3]);
        } else {
          if (inNumberedList) {
            flushNumberedList(); // Flush the numbered list
          }
          currentSection.push(line);
        }
      }

      // Flush any remaining content
      if (inNumberedList) {
        flushNumberedList();
      }
      flushSection();

      let rendered = outputSections.join('\n');

      // Normalize blank lines - collapse multiple consecutive blank lines into one
      rendered = rendered.replace(/\n{3,}/g, '\n\n');

      // Post-process headings - cli-markdown doesn't style them properly
      // Strip ANSI codes for matching, then apply our own styles
      const stripAnsi = (str: string) => str.replace(/\x1B\[[0-9;]*m/g, '');

      const outputLines = rendered.split('\n');
      const result: string[] = [];
      let wasInBulletList = false;

      for (const line of outputLines) {
        const plain = stripAnsi(line);
        const isBulletStart = /^\s*[•\-\*]\s/.test(plain) || /^\s*\d+\.\s/.test(plain);
        const isHeading = /^#{1,6}\s/.test(plain);
        const isBlankLine = plain.trim() === '';

        // Track if we're in a bullet list context
        if (isBulletStart) {
          wasInBulletList = true;
        }

        // Add blank line when transitioning from bullet list to a heading
        if (wasInBulletList && isHeading) {
          result.push('');
          wasInBulletList = false;
        }

        // Reset bullet context on blank lines (list has ended)
        if (isBlankLine) {
          wasInBulletList = false;
        }

        // H1: # Heading
        const h1Match = plain.match(/^# (.+)$/);
        if (h1Match) {
          result.push(chalk.bold.blue.underline(h1Match[1]));
          continue;
        }
        // H2: ## Heading
        const h2Match = plain.match(/^## (.+)$/);
        if (h2Match) {
          result.push(chalk.bold.blue(h2Match[1]));
          continue;
        }
        // H3: ### Heading
        const h3Match = plain.match(/^### (.+)$/);
        if (h3Match) {
          result.push(chalk.bold.cyan(h3Match[1]));
          continue;
        }
        // H4+: #### Heading
        const h4Match = plain.match(/^#{4,} (.+)$/);
        if (h4Match) {
          result.push(chalk.bold(h4Match[1]));
          continue;
        }
        result.push(line);
      }

      return result.join('\n');
    } catch (err) {
      console.error('Markdown render error:', err);
      return content;
    }
  }, [content, width]);
}
