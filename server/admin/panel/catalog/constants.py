"""探索任务目录（server/catalog.json）的共享常量。

与 scripts/generate-catalog.mjs 的约束保持一致；生成脚本是最终校验权威，
这里的常量用于表单选项与后台交互（排序边界、字段投影）。
"""

CATEGORIES = ['观察', '感知', '创作', '休息', '记录', '同行']

PREFERENCES = ['安静独处', '熟人同行', '观察细节', '动手创作', '尝试新鲜', '熟悉安心']

ROLE_LABELS = {
    'student': '学生',
    'employee': '上班族',
    'freelancer': '自由工作者',
    'leader': '经营者 / 团队负责人',
    'caregiver': '家庭照护者',
    'retired': '退休生活',
    'transition': '生活过渡期',
    'other': '其他身份',
}

# 必填字段（写盘时的字段顺序）
ITEM_FIELDS = ['id', 'title', 'subtitle', 'category', 'minutes', 'steps', 'hint', 'roleHints', 'preferenceTags']

# 可选字段：enabled=False 表示停用（缺省即启用）。停用的任务仍留在目录中
# （历史记录与已激活任务照常展示），但不会被推荐、轮换到。
OPTIONAL_ITEM_FIELDS = ('enabled',)

# 目录前 16 条为原始任务，顺序被生成脚本锁定（originalIds 检查），后台不提供移动。
ORIGINAL_COUNT = 16
