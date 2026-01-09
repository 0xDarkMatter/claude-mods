import React, { useMemo, useEffect } from 'react';
import { Box, Text, useStdout } from 'ink';
import { useMarkdown } from '../hooks/useMarkdown.js';

interface MarkdownViewProps {
  content: string;
  scrollOffset: number;
  maxHeight: number;
  onLineCount?: (count: number) => void;
}

export const MarkdownView: React.FC<MarkdownViewProps> = ({
  content,
  scrollOffset,
  maxHeight,
  onLineCount
}) => {
  const { stdout } = useStdout();
  const width = stdout?.columns || 80;
  const rendered = useMarkdown(content, width);

  // Split into lines for scrolling
  const lines = useMemo(() => {
    return rendered.split('\n');
  }, [rendered]);

  // Calculate visible window
  const totalLines = lines.length;

  // Report line count to parent for scroll bounds
  useEffect(() => {
    onLineCount?.(totalLines);
  }, [totalLines, onLineCount]);
  const clampedOffset = Math.min(scrollOffset, Math.max(0, totalLines - maxHeight));
  const visibleLines = lines.slice(clampedOffset, clampedOffset + maxHeight);

  // Scroll indicator
  const showScrollUp = clampedOffset > 0;
  const showScrollDown = clampedOffset + maxHeight < totalLines;

  return (
    <Box flexDirection="column" paddingX={1} paddingY={1}>
      {showScrollUp && (
        <Text color="gray">--- more above ({clampedOffset} lines) ---</Text>
      )}

      {visibleLines.map((line, index) => (
        <Text key={`${clampedOffset}-${index}`}>{line || ' '}</Text>
      ))}

      {showScrollDown && (
        <Text color="gray">--- more below ({totalLines - clampedOffset - maxHeight} lines) ---</Text>
      )}
    </Box>
  );
};
