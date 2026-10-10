import 'dart:collection';

class RoleOption {
  const RoleOption(this.id, this.label, this.subtitle);
  final String id;
  final String label;
  final String subtitle;
}

const roles = <RoleOption>[
  RoleOption('student', '学生', '在课间和日常里发现一点不同'),
  RoleOption('employee', '上班族', '给忙碌的一天留一点呼吸'),
  RoleOption('freelancer', '自由工作者', '在自己的节奏里轻轻探索'),
  RoleOption('leader', '经营者 / 团队负责人', '暂时放下待办，看看身边'),
  RoleOption('caregiver', '家庭照护者', '给照顾他人的自己一点时间'),
  RoleOption('retired', '退休生活', '熟悉的日常也有新发现'),
  RoleOption('transition', '生活过渡期', '不着急，先从一件小事开始'),
  RoleOption('other', '其他身份', '按照舒服的方式探索'),
];
const roleOptions = roles;
const preferences = <String>['安静独处', '熟人同行', '观察细节', '动手创作', '尝试新鲜', '熟悉安心'];
const preferenceOptions = preferences;

class Quest {
  const Quest({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.category,
    required this.minutes,
    required this.steps,
    required this.hint,
    this.roleHints = const {},
  });
  final String id;
  final String title;
  final String subtitle;
  final String category;
  final int minutes;
  final List<String> steps;
  final String hint;
  final Map<String, String> roleHints;
}

const questCatalog = <Quest>[
  Quest(
    id: 'green',
    title: '三种绿色',
    subtitle: '给平常的世界，换一种看法。',
    category: '观察',
    minutes: 5,
    steps: ['在熟悉的室内或安全的附近，找三种绿色。', '看看它们偏黄、偏蓝，还是带一点灰。', '用一句话记录最喜欢的那一种。'],
    hint: '绿植、包装、书封面都可以；不用出门，也不用拍照。',
    roleHints: {
      'student': '课间看看文具、书本或窗边绿植。',
      'employee': '休息时，在办公桌附近找找绿色。',
      'freelancer': '暂停手头工作，看看桌边的颜色。',
      'leader': '两件待办之间，给自己五分钟。',
      'caregiver': '照护间隙，在身边找三种绿色。',
    },
  ),
  Quest(
    id: 'light',
    title: '一小片光',
    subtitle: '光落在哪里，日常就有了新层次。',
    category: '观察',
    minutes: 5,
    steps: ['在熟悉的室内找一片自然光或灯光。', '观察它落在物体上的颜色与边缘。', '写下让你停留的一处细节。'],
    hint: '只看反射的光，不直视太阳或强光，不攀爬、不靠近窗外。',
  ),
  Quest(
    id: 'texture',
    title: '指尖的纹理',
    subtitle: '用触感重新认识一个日常物件。',
    category: '感知',
    minutes: 5,
    steps: ['选一个干净、安全、属于你的物件。', '轻轻感受它的表面：光滑、粗糙或柔软？', '用三个词描述它。'],
    hint: '纸张、衣袖或木桌都可以；不触摸尖锐、烫手或不明物品。',
  ),
  Quest(
    id: 'sounds',
    title: '一分钟声音地图',
    subtitle: '不录音，也能留下一段声音。',
    category: '感知',
    minutes: 5,
    steps: ['在安全安静的地方坐好。', '用一分钟听听近处和远处的环境声。', '用文字记下两种声音和你的感受。'],
    hint: '无需录音、不记录他人对话；听觉不便时可以改为观察两种轻微运动。',
  ),
  Quest(
    id: 'sky',
    title: '窗边的天空',
    subtitle: '熟悉的窗景，每天都不一样。',
    category: '观察',
    minutes: 5,
    steps: ['站在安全的室内位置看看窗景。', '找一种天空或远处景物的颜色。', '给此刻的颜色起一个名字。'],
    hint: '不靠近窗沿、不向窗外探身；没有窗户时，观察一张自己的风景照片。',
  ),
  Quest(
    id: 'corner',
    title: '一个角落的新角度',
    subtitle: '不用远行，也能发现新的画面。',
    category: '观察',
    minutes: 5,
    steps: ['选择家里一个熟悉的角落。', '坐下或站稳，从不同高度看一眼。', '写下平时没有注意到的细节。'],
    hint: '不搬动重物、不攀爬；只在舒服、安全的位置观察。',
  ),
  Quest(
    id: 'color',
    title: '今日配色',
    subtitle: '把今天的心情，装进三种颜色。',
    category: '创作',
    minutes: 5,
    steps: ['看看身边三个已有物品。', '挑出三种愿意放在一起的颜色。', '为这组配色起个名字。'],
    hint: '不需要购物；可以只用文字，不必挪动或拍下物品。',
  ),
  Quest(
    id: 'leaves',
    title: '叶子的线条',
    subtitle: '一片小叶子，也藏着自己的地图。',
    category: '观察',
    minutes: 5,
    steps: ['观察一株熟悉的绿植或植物照片。', '看看叶缘、叶脉和弯曲的方向。', '用一句话描绘它的形状。'],
    hint: '只观察、不采摘、不触碰未知植物；室内照片也算完成。',
  ),
  Quest(
    id: 'object',
    title: '日常物件的新名字',
    subtitle: '给熟悉的东西一点想象力。',
    category: '创作',
    minutes: 5,
    steps: ['选一个手边的普通物件。', '想象你第一次见到它，会怎样形容？', '给它起一个有趣的新名字。'],
    hint: '杯子、笔或钥匙都可以；不用透露住址、钥匙细节或个人信息。',
  ),
  Quest(
    id: 'shadow',
    title: '影子的形状',
    subtitle: '看看光背后的小小图案。',
    category: '观察',
    minutes: 5,
    steps: ['在安全的室内找一个影子。', '观察它像什么、边缘是否清晰。', '用几个词描述这个小图案。'],
    hint: '用现有光线即可；不用强光、明火，也不需要移动电器。',
  ),
  Quest(
    id: 'water',
    title: '认真喝一杯水',
    subtitle: '把一个习惯动作，变成短暂休息。',
    category: '感知',
    minutes: 5,
    steps: ['如果身体情况允许，准备平时会喝的适温饮品。', '坐稳，按舒服的节奏喝一小口。', '记下杯子的触感或这一刻的心情。'],
    hint: '遵循个人医嘱，不强迫饮水；也可以只观察杯子的颜色和形状。',
  ),
  Quest(
    id: 'lines',
    title: '身边的三条线',
    subtitle: '世界也可以是一张简单的画。',
    category: '观察',
    minutes: 5,
    steps: ['看看身边物品的边缘。', '找到一条直线、一条曲线和一条你喜欢的线。', '写下它们让你想到什么。'],
    hint: '书页、衣服和桌沿都可以；不用触碰电线或任何危险设施。',
  ),
  Quest(
    id: 'paper',
    title: '一张纸的小创作',
    subtitle: '不需要技巧，也可以留下一个小作品。',
    category: '创作',
    minutes: 10,
    steps: ['找一张已有的废纸和一支笔。', '随意画三条线，再添一点你喜欢的形状。', '给这张小画起个名字。'],
    hint: '不用剪刀、胶水或购买材料；没有纸笔时，用文字描述想画的东西。',
  ),
  Quest(
    id: 'detail',
    title: '被忽略的小细节',
    subtitle: '熟悉不是没有惊喜，只是看得太快。',
    category: '观察',
    minutes: 5,
    steps: ['选一个每天都能看到的安全物件。', '认真看半分钟，找一处此前没注意的细节。', '记录这次新发现。'],
    hint: '只观察自己的物品；不翻看他人物品、文件或屏幕。',
  ),
  Quest(
    id: 'pause',
    title: '五分钟留白',
    subtitle: '今天也可以什么都不赶。',
    category: '休息',
    minutes: 5,
    steps: ['在安全舒服的位置坐一会儿。', '放下不紧急的事，看看一个让你自在的物件。', '用一个词记下此刻的状态。'],
    hint: '不用闭眼、憋气或做规定动作；不舒服就停止，休息本身已经很好。',
  ),
  Quest(
    id: 'gratitude',
    title: '写给今天的小感谢',
    subtitle: '留住一件很小、但真实的好事。',
    category: '记录',
    minutes: 5,
    steps: ['回想今天一件还不错的小事。', '写一两句话，留给现在或将来的自己。', '如果今天很难，也可以只写“我已经尽力了”。'],
    hint: '不用强迫积极，不必联系别人，也无需分享私密经历。',
  ),
];

Quest questById(String id) => questCatalog.firstWhere(
  (q) => q.id == id,
  orElse: () => questCatalog.first,
);
String nextQuestId(String id) =>
    questCatalog[(questCatalog.indexWhere((q) => q.id == id) + 1) %
            questCatalog.length]
        .id;
String localDay(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class UserProfile {
  UserProfile({
    required this.id,
    required this.nickname,
    required this.role,
    required List<String> preferences,
  }) : preferences = UnmodifiableListView(preferences);
  final String id;
  final String nickname;
  final String role;
  final List<String> preferences;
  Map<String, dynamic> toJson() => {
    'id': id,
    'nickname': nickname,
    'role': role,
    'preferences': preferences,
  };
  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: json['id'] as String,
    nickname: json['nickname'] as String,
    role: json['role'] as String,
    preferences: List<String>.from(json['preferences'] as List? ?? []),
  );
}

class JournalEntry {
  const JournalEntry({
    required this.id,
    required this.questId,
    required this.questTitle,
    required this.text,
    required this.createdAt,
  });
  final String id;
  final String questId;
  final String questTitle;
  final String text;
  final DateTime createdAt;
  Map<String, dynamic> toJson() => {
    'id': id,
    'questId': questId,
    'questTitle': questTitle,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
  };
  factory JournalEntry.fromJson(Map<String, dynamic> json) => JournalEntry(
    id: json['id'] as String,
    questId: json['questId'] as String,
    questTitle: json['questTitle'] as String,
    text: json['text'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

const _unchanged = Object();

class AppSnapshot {
  AppSnapshot({
    this.profile,
    this.activeQuestId,
    this.recommendedQuestId = 'green',
    List<JournalEntry> entries = const [],
    this.replacedOn,
    this.draft = '',
    required this.day,
    this.canRequestNext = false,
  }) : entries = UnmodifiableListView(entries);
  final UserProfile? profile;
  final String? activeQuestId;
  final String recommendedQuestId;
  final List<JournalEntry> entries;
  final String? replacedOn;
  final String draft;
  final String day;
  final bool canRequestNext;
  bool get replacementAvailable => replacedOn != day;
  AppSnapshot copyWith({
    Object? profile = _unchanged,
    Object? activeQuestId = _unchanged,
    String? recommendedQuestId,
    List<JournalEntry>? entries,
    Object? replacedOn = _unchanged,
    String? draft,
    String? day,
    bool? canRequestNext,
  }) => AppSnapshot(
    profile: identical(profile, _unchanged)
        ? this.profile
        : profile as UserProfile?,
    activeQuestId: identical(activeQuestId, _unchanged)
        ? this.activeQuestId
        : activeQuestId as String?,
    recommendedQuestId: recommendedQuestId ?? this.recommendedQuestId,
    entries: entries ?? this.entries,
    replacedOn: identical(replacedOn, _unchanged)
        ? this.replacedOn
        : replacedOn as String?,
    draft: draft ?? this.draft,
    day: day ?? this.day,
    canRequestNext: canRequestNext ?? this.canRequestNext,
  );
  Map<String, dynamic> toJson() => {
    'profile': profile?.toJson(),
    'activeQuestId': activeQuestId,
    'recommendedQuestId': recommendedQuestId,
    'entries': entries.map((e) => e.toJson()).toList(),
    'replacedOn': replacedOn,
    'draft': draft,
    'day': day,
    'canRequestNext': canRequestNext,
  };
  factory AppSnapshot.fromJson(Map<String, dynamic> json) => AppSnapshot(
    profile: json['profile'] == null
        ? null
        : UserProfile.fromJson(
            Map<String, dynamic>.from(json['profile'] as Map),
          ),
    activeQuestId: json['activeQuestId'] as String?,
    recommendedQuestId: json['recommendedQuestId'] as String? ?? 'green',
    entries: (json['entries'] as List? ?? [])
        .map((e) => JournalEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    replacedOn: json['replacedOn'] as String?,
    draft: json['draft'] as String? ?? '',
    day: json['day'] as String? ?? localDay(DateTime.now()),
    canRequestNext: json['canRequestNext'] as bool? ?? false,
  );
}

class QuestException implements Exception {
  const QuestException(this.message);
  final String message;
  @override
  String toString() => message;
}
