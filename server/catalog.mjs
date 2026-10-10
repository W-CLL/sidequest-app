import { readFileSync } from 'node:fs';
export const quests = Object.freeze(JSON.parse(readFileSync(new URL('./catalog.json', import.meta.url), 'utf8')).map(Object.freeze));
function knownQuestIndex(id) {
  const index = quests.findIndex(q => q.id === id);
  if (index < 0) throw new RangeError(`Unknown activity ID: ${id}`);
  return index;
}
export function nextQuest(id) { return quests[(knownQuestIndex(id) + 1) % quests.length].id; }
export function questTitle(id) { return quests[knownQuestIndex(id)].title; }
export function appendRecommendation(history, id) { return [...history, id].slice(-40); }
export function recommendQuest({ preferences = [], history = [], currentId = null } = {}) {
  const ids = quests.map(q => q.id);
  const valid = history.filter(id => ids.includes(id));
  const recent = valid.slice(-7);
  let candidates = quests.filter(q => q.id !== currentId && !recent.includes(q.id));
  while (!candidates.length && recent.length) {
    recent.shift();
    candidates = quests.filter(q => q.id !== currentId && !recent.includes(q.id));
  }
  if (!candidates.length) return ids[0];
  const current = ids.indexOf(currentId);
  const distance = id => current < 0 ? ids.indexOf(id) : (ids.indexOf(id) - current + ids.length) % ids.length;
  const score = q => q.preferenceTags.filter(p => preferences.includes(p)).length;
  candidates.sort((a,b) => score(b) - score(a) || valid.lastIndexOf(a.id) - valid.lastIndexOf(b.id) || distance(a.id) - distance(b.id));
  return candidates[0].id;
}
