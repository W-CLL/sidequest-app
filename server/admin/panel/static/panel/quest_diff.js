/* 支线管理后台：探索任务保存前的变更预览（差异面板）。
 *
 * 独立于抽屉交互：只负责「从表单构建任务对象 → 与现有条目对比 → 生成预览 HTML」。
 * quest_drawer.js 在表单提交时调用 window.SqQuestDiff.render(...)，返回 null 表示
 * 无法预览（此时调用方直接提交，保持与旧版一致的行为）。
 */
(function () {
    'use strict';

    var FIELD_ROWS = [
        ['title', '标题'],
        ['subtitle', '一句话描述'],
        ['category', '分类'],
        ['minutes', '时长（分钟）'],
        ['hint', '提示'],
    ];

    function el(form, name) {
        return form.querySelector('[name="' + name + '"]');
    }

    function text(form, name) {
        var input = el(form, name);
        return input ? String(input.value || '').trim() : '';
    }

    function number(form, name) {
        var input = el(form, name);
        return input ? Number(input.value) : NaN;
    }

    function checked(form, name) {
        var input = el(form, name);
        return !!(input && input.checked);
    }

    function tagList(form) {
        var boxes = form.querySelectorAll('[name="preference_tags"]');
        var list = [];
        for (var i = 0; i < boxes.length; i++) {
            if (boxes[i].checked) {
                list.push(boxes[i].value);
            }
        }
        return list;
    }

    function roleHints(form, rolesData) {
        var out = {};
        Object.keys(rolesData || {}).forEach(function (role) {
            var value = text(form, 'role_' + role);
            if (value) {
                out[role] = value;
            }
        });
        return out;
    }

    /* 编辑时保留原条目的标签/角色提示顺序（与服务端 build_quest 一致）：
       无改动的提交不应产生「幻影差异」。 */
    function preserveOrder(values, previous) {
        var known = previous.filter(function (value) {
            return values.indexOf(value) !== -1;
        });
        return known.concat(values.filter(function (value) {
            return known.indexOf(value) === -1;
        }));
    }

    function reorderKeys(mapping, previous) {
        var known = Object.keys(previous).filter(function (key) {
            return Object.prototype.hasOwnProperty.call(mapping, key);
        });
        var out = {};
        known.forEach(function (key) {
            out[key] = mapping[key];
        });
        Object.keys(mapping).forEach(function (key) {
            if (known.indexOf(key) === -1) {
                out[key] = mapping[key];
            }
        });
        return out;
    }

    /* 与服务端 QuestForm.build_quest 保持一致：停用时才带 enabled=false。 */
    function buildQuest(form, rolesData, previous) {
        var hints = roleHints(form, rolesData);
        var tags = tagList(form);
        if (previous) {
            tags = preserveOrder(tags, previous.preferenceTags || []);
            hints = reorderKeys(hints, previous.roleHints || {});
        }
        var quest = {
            id: text(form, 'quest_id'),
            title: text(form, 'title'),
            subtitle: text(form, 'subtitle'),
            category: text(form, 'category'),
            minutes: number(form, 'minutes'),
            steps: [text(form, 'step_1'), text(form, 'step_2'), text(form, 'step_3')].filter(function (step) {
                return step;
            }),
            hint: text(form, 'hint'),
            roleHints: hints,
            preferenceTags: tags,
        };
        if (!checked(form, 'enabled')) {
            quest.enabled = false;
        }
        return quest;
    }

    function diffQuest(oldQuest, newQuest, rolesData) {
        var changes = [];
        function push(label, from, to) {
            changes.push({ label: label, from: from, to: to });
        }
        FIELD_ROWS.forEach(function (pair) {
            var from = oldQuest[pair[0]];
            var to = newQuest[pair[0]];
            if (String(from) !== String(to)) {
                push(pair[1], from, to);
            }
        });
        var oldSteps = (oldQuest.steps || []).join('；');
        var newSteps = (newQuest.steps || []).join('；');
        if (oldSteps !== newSteps) {
            push('步骤', oldSteps, newSteps);
        }
        var oldTags = (oldQuest.preferenceTags || []).join('、');
        var newTags = (newQuest.preferenceTags || []).join('、');
        if (oldTags !== newTags) {
            push('偏好标签', oldTags, newTags);
        }
        Object.keys(rolesData || {}).forEach(function (role) {
            var from = (oldQuest.roleHints || {})[role] || '';
            var to = (newQuest.roleHints || {})[role] || '';
            if (from !== to) {
                push('角色提示 · ' + rolesData[role], from, to);
            }
        });
        var oldEnabled = oldQuest.enabled !== false;
        var newEnabled = newQuest.enabled !== false;
        if (oldEnabled !== newEnabled) {
            push('启用状态', oldEnabled ? '启用' : '停用', newEnabled ? '启用' : '停用');
        }
        return changes;
    }

    function esc(value) {
        var div = document.createElement('div');
        div.textContent = value == null ? '' : String(value);
        return div.innerHTML;
    }

    function cells(value) {
        return esc(value) || '<span class="sqd-preview-empty">（空）</span>';
    }

    function renderTable(rows, threeColumns) {
        var html = '<table class="sqd-preview-table"><tbody>';
        rows.forEach(function (row) {
            html += '<tr><td class="name">' + esc(row.label) + '</td>' +
                (threeColumns ? '<td class="from">' + cells(row.from) + '</td>' : '') +
                '<td class="to"' + (threeColumns ? '' : ' colspan="2"') + '>' + cells(row.to) + '</td></tr>';
        });
        return html + '</tbody></table>';
    }

    /* mode: 'add' | 'edit'；返回预览 HTML；无法预览（如找不到原任务）时返回 null。 */
    function render(questsData, mode, id, form, rolesData) {
        var oldQuest = null;
        if (mode === 'edit') {
            for (var i = 0; i < questsData.length; i++) {
                if (questsData[i].id === id) {
                    oldQuest = questsData[i];
                }
            }
            if (!oldQuest) {
                return null;
            }
        }
        var newQuest = buildQuest(form, rolesData, oldQuest);
        if (mode === 'edit') {
            var changes = diffQuest(oldQuest, newQuest, rolesData);
            if (!changes.length) {
                return '<div class="sqd-preview-note">内容与当前版本一致；点击「确认保存」仍会重新生成客户端文件。</div>';
            }
            return renderTable(changes, true);
        }
        var rows = [
            { label: '活动 ID', to: newQuest.id },
            { label: '标题', to: newQuest.title },
            { label: '一句话描述', to: newQuest.subtitle },
            { label: '分类', to: newQuest.category },
            { label: '时长（分钟）', to: newQuest.minutes },
            { label: '步骤', to: (newQuest.steps || []).join('；') },
            { label: '提示', to: newQuest.hint },
            { label: '偏好标签', to: (newQuest.preferenceTags || []).join('、') },
        ];
        if (newQuest.enabled === false) {
            rows.push({ label: '启用状态', to: '停用（不再被推荐）' });
        }
        return renderTable(rows, false);
    }

    window.SqQuestDiff = { render: render, buildQuest: buildQuest };
})();
