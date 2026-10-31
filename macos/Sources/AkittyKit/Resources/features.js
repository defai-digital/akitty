"use strict";
var AkittyFeatures = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // typescript/src/palette.ts
  var palette_exports = {};
  __export(palette_exports, {
    commands: () => commands,
    listCommands: () => listCommands
  });
  var commands = Object.freeze([
    { id: "new-window", title: "New Window", shortcut: "\u2318N", keywords: ["terminal", "shell"] },
    { id: "new-tab", title: "New Tab", shortcut: "\u2318T", keywords: ["terminal", "shell"] },
    { id: "split", title: "Split Pane", shortcut: "\u2318D", keywords: ["vertical", "side by side"] },
    { id: "close-pane", title: "Close Pane", shortcut: "\u2318W", keywords: ["close", "shell"] },
    { id: "copy", title: "Copy Selection", shortcut: "\u2318C", keywords: ["clipboard"] },
    { id: "paste", title: "Paste Text", shortcut: "\u2318V", keywords: ["clipboard"] },
    { id: "find", title: "Find in Scrollback", shortcut: "\u2318F", keywords: ["search", "history"] },
    { id: "find-next", title: "Find Next", shortcut: "\u2318G", keywords: ["search", "next"] },
    { id: "find-previous", title: "Find Previous", shortcut: "\u2318\u21E7G", keywords: ["search", "previous"] },
    { id: "font-increase", title: "Increase Font Size", shortcut: "\u2318+", keywords: ["zoom", "larger"] },
    { id: "font-decrease", title: "Decrease Font Size", shortcut: "\u2318\u2212", keywords: ["zoom", "smaller"] },
    { id: "font-reset", title: "Reset Font Size", shortcut: "\u23180", keywords: ["zoom", "default"] },
    { id: "agent-overview", title: "Agent Overview", shortcut: "\u2325\u2318A", keywords: ["agents", "control", "reclaim", "sessions"] }
  ]);
  function plainLine(value) {
    return value.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ").trim();
  }
  function listCommands(query) {
    if (typeof query !== "string" || query.length > 512) throw new RangeError("Invalid palette query");
    const needle = Array.from(plainLine(query).normalize("NFKC").toLowerCase()).slice(0, 128);
    const ranked = [];
    for (const [index, command] of commands.entries()) {
      const haystack = Array.from([command.title, command.id, ...command.keywords].join(" ").normalize("NFKC").toLowerCase());
      let cursor = 0;
      let score = 0;
      let matches = true;
      for (const character of needle) {
        const found = haystack.indexOf(character, cursor);
        if (found < 0) {
          matches = false;
          break;
        }
        score += found - cursor;
        cursor = found + 1;
      }
      if (matches && needle.length > 0 && haystack.join("").includes(needle.join(""))) score -= 1e3;
      if (matches) ranked.push({ command, score, index });
    }
    ranked.sort((a, b) => a.score - b.score || a.index - b.index);
    return JSON.stringify({ version: 1, commands: ranked.map(({ command }) => command) });
  }
  return __toCommonJS(palette_exports);
})();
