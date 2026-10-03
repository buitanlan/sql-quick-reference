import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const writeToc = process.argv.includes('--write-toc');
const errors = [];
const documents = new Map();

// GitHub-style anchors for the plain-text/inline-code headings used in this repo.
function slug(text) {
  return text.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/<[^>]*>/g, '').replace(/\\([\p{P}\p{S}])/gu, '$1')
    .toLowerCase().replace(/[^\p{L}\p{M}\p{N}_\- ]/gu, '').replace(/ /g, '-');
}

function parse(file, content) {
  const headings = [];
  const links = [];
  const counts = new Map();
  let fence = null;
  let fenceLine = 0;
  for (const [index, line] of content.split(/\r?\n/).entries()) {
    const marker = line.match(/^\s{0,3}(`{3,}|~{3,})(.*)$/);
    if (marker) {
      if (!fence) {
        fence = marker[1];
        fenceLine = index + 1;
      } else if (marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) {
        fence = null;
      }
      continue;
    }
    if (fence) continue;
    const heading = line.match(/^(#{1,6})\s+(.+?)(?:\s+#+)?$/);
    if (heading) {
      const base = slug(heading[2]);
      const number = counts.get(base) ?? 0;
      counts.set(base, number + 1);
      headings.push({ level: heading[1].length, text: heading[2], anchor: base + (number ? `-${number}` : ''), line: index + 1 });
    }
    // Link labels may contain escaped or balanced brackets, e.g. CHECK [NOT].
    for (const match of line.matchAll(/\[(?:\\.|[^\[\]\\]|\[(?:\\.|[^\]\\])*\])+\]\(([^\s)]*)\)/g)) {
      links.push({ target: match[1], line: index + 1 });
    }
  }
  if (fence) errors.push(`${file}:${fenceLine}: unclosed code fence`);
  if (headings.filter(h => h.level === 1).length !== 1) errors.push(`${file}: expected one H1 title`);
  return { content, headings, links };
}

function collect(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.name.startsWith('.') || ['node_modules', 'vendor'].includes(entry.name)) continue;
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) collect(absolute);
    else if (entry.name.endsWith('.md')) {
      let content = fs.readFileSync(absolute, 'utf8');
      const relative = path.relative(root, absolute);
      let parsed = parse(relative, content);
      if (writeToc && content.includes('## Mục lục')) {
        const tocHeading = parsed.headings.find(h => h.text === 'Mục lục');
        const toc = parsed.headings.filter(h => h.line > tocHeading.line && [2, 3].includes(h.level))
          .map(h => `${h.level === 3 ? '  ' : ''}- [${h.text}](#${h.anchor})`).join('\n');
        // A callback keeps literal $ sequences in headings from being expanded.
        // Stop at the next H2 instead of a thematic break inside a malformed TOC.
        content = content.replace(/^## Mục lục\r?\n[\s\S]*?(?=^## )/m,
          () => `## Mục lục\n\n${toc}\n\n---\n\n`);
        const newline = parsed.content.includes('\r\n') ? '\r\n' : '\n';
        content = content.replace(/\r?\n/g, newline);
        fs.writeFileSync(absolute, content);
        parsed = parse(relative, content);
      }
      documents.set(absolute, parsed);
    }
  }
}

collect(root);
let checkedLinks = 0;
for (const [file, doc] of documents) {
  for (const link of doc.links) {
    if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(link.target)) continue;
    checkedLinks++;
    const [name, fragment] = link.target.split('#');
    let destination;
    let anchor;
    try {
      destination = name ? path.resolve(path.dirname(file), decodeURIComponent(name)) : file;
      anchor = fragment ? decodeURIComponent(fragment) : null;
    } catch {
      errors.push(`${path.relative(root, file)}:${link.line}: invalid URL encoding ${link.target}`);
      continue;
    }
    if (!fs.existsSync(destination)) {
      errors.push(`${path.relative(root, file)}:${link.line}: missing file ${link.target}`);
    } else if (anchor && !documents.get(destination)?.headings.some(h => h.anchor === anchor)) {
      errors.push(`${path.relative(root, file)}:${link.line}: missing anchor ${link.target}`);
    }
  }
  const toc = doc.headings.find(h => h.text === 'Mục lục');
  if (toc) {
    const next = doc.headings.find(h => h.line > toc.line);
    const tocLinks = doc.links.filter(l => l.line > toc.line && l.line < (next?.line ?? Infinity)).map(l => l.target);
    for (const h of doc.headings.filter(h => h.line > toc.line && [2, 3].includes(h.level))) {
      if (!tocLinks.includes(`#${h.anchor}`)) errors.push(`${path.relative(root, file)}:${h.line}: heading missing from TOC: ${h.text}`);
    }
  }
}

if (errors.length) {
  console.error(errors.join('\n'));
  console.error(`FAIL: ${errors.length} documentation issue(s)`);
  process.exitCode = 1;
} else {
  console.log(`PASS: ${documents.size} Markdown files, ${checkedLinks} local links, code fences and tables of contents.`);
}
