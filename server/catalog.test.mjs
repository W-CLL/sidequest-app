import test from 'node:test';
import assert from 'node:assert/strict';
import { quests, nextQuest, questTitle, recommendQuest, appendRecommendation, firstEnabledId } from './catalog.mjs';
import { generateDart, validateCatalog, isEnabled } from '../scripts/generate-catalog.mjs';

test('catalog rejects unknown IDs instead of silently replacing their meaning', () => {
  assert.equal(nextQuest('gratitude'), 'fold');
  assert.equal(questTitle('green'), '三种绿色');
  assert.throws(() => nextQuest('unknown'), /Unknown activity/);
  assert.throws(() => questTitle('unknown'), /Unknown activity/);
});

test('generator validates all fields, original IDs, role values and unique preference tags', () => {
  validateCatalog(quests);
  const mutations = [
    item => { item.title = ''; }, item => { item.subtitle = ' '; }, item => { item.category = 1; },
    item => { item.hint = null; }, item => { item.minutes = '5'; }, item => { item.minutes = 5.5; },
    item => { item.minutes = 11; }, item => { item.steps = ['']; }, item => { item.steps = [1]; },
    item => { item.steps = 'text'; }, item => { item.roleHints = []; },
    item => { item.roleHints = { invented: 'hint' }; }, item => { item.roleHints = { student: '' }; },
    item => { item.preferenceTags = []; }, item => { item.preferenceTags = ['安静独处','安静独处']; },
    item => { item.preferenceTags = ['不存在的偏好']; }, item => { item.id = '../bad'; },
    item => { item.extra = true; }, item => { delete item.title; },
  ];
  for (const mutate of mutations) {
    const catalog = structuredClone(quests); mutate(catalog[0]); assert.throws(() => validateCatalog(catalog), /Invalid catalog/);
  }
  const reordered = structuredClone(quests); [reordered[0],reordered[1]] = [reordered[1],reordered[0]];
  assert.throws(() => validateCatalog(reordered), /original 16/);
  const duplicate = structuredClone(quests); duplicate[39].id = duplicate[0].id; assert.throws(() => validateCatalog(duplicate), /unique/);
  const uncovered = structuredClone(quests); for (const quest of uncovered) quest.preferenceTags = ['安静独处']; assert.throws(() => validateCatalog(uncovered), /Too few/);
  const starving = structuredClone(quests); for (const quest of starving) if (quest.preferenceTags.includes('安静独处')) quest.enabled = false; assert.throws(() => validateCatalog(starving), /Too few/);
  const disabledOk = structuredClone(quests); disabledOk[5].enabled = false; validateCatalog(disabledOk);
  for (const mutate of [item => { item.enabled = 'yes'; }, item => { item.enabled = 1; }]) {
    const catalog = structuredClone(quests); mutate(catalog[0]); assert.throws(() => validateCatalog(catalog), /Invalid catalog/);
  }
  const disabledGenerated = generateDart(disabledOk);
  assert.ok(disabledGenerated.includes('enabled: false'));
  assert.ok(!disabledGenerated.includes('enabled: true'));
});

test('disabled activities stay resolvable but are skipped by recommendation and cycling', () => {
  const pool = structuredClone(quests).map(quest => ({ ...quest }));
  assert.equal(questTitle('light'), '一小片光'); // 全目录（含停用）都能查到标题
  pool[1].enabled = false; // 停用 'light'
  assert.equal(isEnabled(pool[0]), true);
  assert.equal(isEnabled(pool[1]), false);
  assert.equal(nextQuest('green', pool), 'texture');
  assert.equal(nextQuest('light', pool), 'texture');
  assert.equal(questTitle('light'), '一小片光');
  const sequence = [];
  let history = [], currentId = null;
  for (let iteration = 0; iteration < 80; iteration += 1) {
    const next = recommendQuest({ preferences: [], history, currentId, pool });
    assert.notEqual(next, 'light');
    sequence.push(next);
    history = appendRecommendation(history, next);
    currentId = next;
  }
  assert.equal(sequence.length, 80);
  const dark = structuredClone(quests).map(quest => ({ ...quest, enabled: false }));
  assert.equal(firstEnabledId(dark), dark[0].id);
  assert.equal(recommendQuest({ pool: dark }), dark[0].id);
});

test('generator escapes Dart interpolation, quotes and multiline text deterministically', () => {
  const catalog = structuredClone(quests); catalog[0].title = '金额 $5 与 "引号"'; catalog[0].hint = '第一行\n第二行';
  const generated = generateDart(catalog);
  assert.ok(generated.includes('金额 \\$5 与 \\"引号\\"')); assert.ok(generated.includes('第一行\\n第二行'));
  assert.equal(generateDart(catalog), generated);
});
