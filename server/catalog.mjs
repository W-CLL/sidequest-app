// Keep IDs and order in sync with the Flutter quest catalog.
export const quests = Object.freeze([
  ['green', '三种绿色'], ['light', '一小片光'],
  ['texture', '指尖的纹理'], ['sounds', '一分钟声音地图'],
  ['sky', '窗边的天空'], ['corner', '一个角落的新角度'],
  ['color', '今日配色'], ['leaves', '叶子的线条'],
  ['object', '日常物件的新名字'], ['shadow', '影子的形状'],
  ['water', '认真喝一杯水'], ['lines', '身边的三条线'],
  ['paper', '一张纸的小创作'], ['detail', '被忽略的小细节'],
  ['pause', '五分钟留白'], ['gratitude', '写给今天的小感谢'],
].map(([id, title]) => Object.freeze({ id, title })));

export function nextQuest(id) {
  const index = quests.findIndex((quest) => quest.id === id);
  return quests[(index + 1) % quests.length].id;
}

export function questTitle(id) {
  return quests.find((quest) => quest.id === id)?.title ?? id;
}
