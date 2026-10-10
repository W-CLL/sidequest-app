import test from 'node:test';
import assert from 'node:assert/strict';
import { quests, nextQuest, questTitle } from './catalog.mjs';
import { generateDart, validateCatalog } from '../scripts/generate-catalog.mjs';

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
});

test('generator escapes Dart interpolation, quotes and multiline text deterministically', () => {
  const catalog = structuredClone(quests); catalog[0].title = '金额 $5 与 "引号"'; catalog[0].hint = '第一行\n第二行';
  const generated = generateDart(catalog);
  assert.ok(generated.includes('金额 \\$5 与 \\"引号\\"')); assert.ok(generated.includes('第一行\\n第二行'));
  assert.equal(generateDart(catalog), generated);
});
