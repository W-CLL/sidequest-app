"""目录表单：新增/编辑探索任务（含停用开关）。"""
import re

from django import forms

from .constants import CATEGORIES, PREFERENCES, ROLE_LABELS
from .store import load_catalog

_CONTROL_CHARS = re.compile(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]')


def validate_text(value):
    if not value or value != value.strip() or _CONTROL_CHARS.search(value):
        raise forms.ValidationError('不能为空；首尾不能有空格；不能包含控制字符。')


def _preserve_order(values, previous):
    """新值按原有顺序排列（未变部分顺序不漂移；新值按表单顺序追加）。"""
    known = [value for value in previous if value in values]
    return known + [value for value in values if value not in known]


def _reorder_keys(mapping, previous):
    """字典键按原有顺序排列；新键按表单顺序追加。"""
    known = [key for key in previous if key in mapping]
    remaining = [key for key in mapping if key not in known]
    return {key: mapping[key] for key in known + remaining}


class QuestForm(forms.Form):
    quest_id = forms.CharField(
        label='活动 ID', max_length=64,
        help_text='小写字母开头，可含小写字母 / 数字 / 下划线，全目录唯一。',
        validators=[validate_text],
    )
    title = forms.CharField(label='标题', max_length=40, validators=[validate_text])
    subtitle = forms.CharField(
        label='一句话描述', max_length=80,
        widget=forms.Textarea(attrs={'rows': 2}), validators=[validate_text],
    )
    category = forms.ChoiceField(label='分类', choices=[(name, name) for name in CATEGORIES])
    minutes = forms.IntegerField(label='时长（分钟）', min_value=5, max_value=10, initial=5)
    step_1 = forms.CharField(
        label='步骤 1', max_length=120, widget=forms.Textarea(attrs={'rows': 2}),
        validators=[validate_text],
    )
    step_2 = forms.CharField(
        label='步骤 2', max_length=120, required=False, widget=forms.Textarea(attrs={'rows': 2}),
        validators=[validate_text],
    )
    step_3 = forms.CharField(
        label='步骤 3', max_length=120, required=False, widget=forms.Textarea(attrs={'rows': 2}),
        validators=[validate_text],
    )
    hint = forms.CharField(
        label='提示', max_length=120, widget=forms.Textarea(attrs={'rows': 2}),
        validators=[validate_text],
        help_text='安全提醒与操作建议，风格与现有任务保持一致。',
    )
    preference_tags = forms.MultipleChoiceField(
        label='偏好标签',
        choices=[(name, name) for name in PREFERENCES],
        widget=forms.CheckboxSelectMultiple,
    )
    enabled = forms.BooleanField(
        label='启用（取消勾选 = 停用）',
        required=False,
        initial=True,
        help_text='停用后不再被推荐、轮换到；历史记录与当前已激活的任务不受影响。',
    )

    def __init__(self, *args, editing_id=None, **kwargs):
        self.editing_id = editing_id
        super().__init__(*args, **kwargs)
        for role, label in ROLE_LABELS.items():
            self.fields[f'role_{role}'] = forms.CharField(
                label=f'角色提示 · {label}',
                max_length=120,
                required=False,
                validators=[validate_text],
                widget=forms.TextInput(attrs={'placeholder': '留空 = 该角色不显示专属提示'}),
            )
        if editing_id:
            self.fields['quest_id'].help_text = '编辑模式下不可修改。'
            self.fields['enabled'].help_text = None

    def clean_quest_id(self):
        value = (self.cleaned_data.get('quest_id') or '').strip()
        if self.editing_id:
            if value != self.editing_id:
                raise forms.ValidationError('编辑时活动 ID 不可修改。')
            return value
        if not re.fullmatch(r'[a-z][a-z0-9_]{0,63}', value):
            raise forms.ValidationError('必须是「小写字母开头 + 小写字母/数字/下划线」，最长 64 位。')
        if value in {item['id'] for item in load_catalog()}:
            raise forms.ValidationError('该 ID 已存在，请换一个。')
        return value

    def build_quest(self):
        cleaned = self.cleaned_data
        role_hints = {
            role: cleaned[f'role_{role}'] for role in ROLE_LABELS if cleaned.get(f'role_{role}')
        }
        tags = list(cleaned['preference_tags'])
        if self.editing_id:
            # 编辑时保留原条目的标签/角色提示顺序：无改动的保存不应产生任何差异。
            previous = next(
                (item for item in load_catalog() if item['id'] == self.editing_id), None
            )
            if previous:
                tags = _preserve_order(tags, previous.get('preferenceTags') or [])
                role_hints = _reorder_keys(role_hints, previous.get('roleHints') or {})
        quest = {
            'id': cleaned['quest_id'],
            'title': cleaned['title'],
            'subtitle': cleaned['subtitle'],
            'category': cleaned['category'],
            'minutes': cleaned['minutes'],
            'steps': [cleaned[name] for name in ('step_1', 'step_2', 'step_3') if cleaned.get(name)],
            'hint': cleaned['hint'],
            'roleHints': role_hints,
            'preferenceTags': tags,
        }
        if not cleaned['enabled']:
            quest['enabled'] = False
        return quest
