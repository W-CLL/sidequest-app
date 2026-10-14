import { readFileSync } from 'node:fs';
export const quests = Object.freeze(JSON.parse(readFileSync(new URL('./catalog.json', import.meta.url), 'utf8')).map(Object.freeze));
// 停用（enabled=false）的任务仍是目录的一部分：历史记录、已激活任务照常展示，
// 但不会被推荐、轮换到或作为新用户的初始推荐。
const isEnabled = quest => quest.enabled !== false;
function knownQuestIndex(id, pool = quests) {
  const index = pool.findIndex(q => q.id === id);
  if (index < 0) throw new RangeError(`Unknown activity ID: ${id}`);
  return index;
}
export function nextQuest(id, pool = quests) {
  const start = knownQuestIndex(id, pool);
  for (let step = 1; step <= pool.length; step += 1) {
    const candidate = pool[(start + step) % pool.length];
    if (isEnabled(candidate)) return candidate.id;
  }
  return id;
}
export function questTitle(id) { return quests[knownQuestIndex(id)].title; }
export function firstEnabledId(pool = quests) { return (pool.find(isEnabled) ?? pool[0]).id; }
export function appendRecommendation(history, id) { return [...history, id].slice(-40); }
export function recommendQuest({ preferences = [], history = [], currentId = null, pool = quests } = {}) {
  const ids = pool.map(q => q.id);
  const valid = history.filter(id => ids.includes(id));
  const recent = valid.slice(-7);
  const pickable = () => pool.filter(q => isEnabled(q) && q.id !== currentId && !recent.includes(q.id));
  let candidates = pickable();
  while (!candidates.length && recent.length) {
    recent.shift();
    candidates = pickable();
  }
  if (!candidates.length) return firstEnabledId(pool);
  const current = ids.indexOf(currentId);
  const distance = id => current < 0 ? ids.indexOf(id) : (ids.indexOf(id) - current + ids.length) % ids.length;
  const score = q => q.preferenceTags.filter(p => preferences.includes(p)).length;
  candidates.sort((a,b) => score(b) - score(a) || valid.lastIndexOf(a.id) - valid.lastIndexOf(b.id) || distance(a.id) - distance(b.id));
  return candidates[0].id;
}
