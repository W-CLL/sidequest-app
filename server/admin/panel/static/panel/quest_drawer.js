/* 支线管理后台：探索任务抽屉（查看 / 编辑 / 新增） */
(function () {
    'use strict';

    var questsData = [];
    var rolesData = {};
    var originalCount = 0;
    var skipPreview = false;

    function byId(id) {
        return document.getElementById(id);
    }

    function readJSON(id) {
        var el = byId(id);
        if (!el) {
            return null;
        }
        try {
            return JSON.parse(el.textContent);
        } catch (error) {
            return null;
        }
    }

    function drawer() {
        return byId('sq-drawer');
    }

    function backdrop() {
        return byId('sq-drawer-backdrop');
    }

    function esc(value) {
        var div = document.createElement('div');
        div.textContent = value == null ? '' : String(value);
        return div.innerHTML;
    }

    function openShell(mode, id) {
        var d = drawer();
        if (!d) {
            return;
        }
        d.dataset.open = mode;
        d.dataset.id = id || '';
        var b = backdrop();
        if (b) {
            b.dataset.open = '1';
        }
    }

    function closeDrawer() {
        var d = drawer();
        if (d) {
            d.dataset.open = '';
        }
        var b = backdrop();
        if (b) {
            b.dataset.open = '';
        }
        hidePreview();
    }

    function preview() {
        return byId('sq-drawer-preview');
    }

    function hidePreview() {
        var panel = preview();
        if (panel) {
            panel.style.display = 'none';
            panel.innerHTML = '';
        }
        skipPreview = false;
    }

    function heading(text) {
        var el = byId('sq-drawer-heading');
        if (el) {
            el.textContent = text;
        }
    }

    function showView() {
        var view = byId('sq-drawer-view');
        var actions = byId('sq-drawer-view-actions');
        var form = byId('sq-drawer-form');
        if (view) { view.style.display = ''; }
        if (actions) { actions.style.display = ''; }
        if (form) { form.style.display = 'none'; }
    }

    function showForm() {
        var view = byId('sq-drawer-view');
        var actions = byId('sq-drawer-view-actions');
        var form = byId('sq-drawer-form');
        if (view) { view.style.display = 'none'; }
        if (actions) { actions.style.display = 'none'; }
        if (form) { form.style.display = ''; }
    }

    function findQuest(id) {
        for (var i = 0; i < questsData.length; i++) {
            if (questsData[i].id === id) {
                return questsData[i];
            }
        }
        return null;
    }

    function renderView(quest) {
        var roles = rolesData || {};
        var html = '';
        html += '<h2 class="sqd-title">' + esc(quest.title) + '</h2>';
        html += '<div class="sqd-meta">' + esc(quest.id) + ' · ' + esc(quest.category) +
                ' · ' + esc(quest.minutes) + ' 分钟</div>';
        if (quest.enabled === false) {
            html += '<div class="sqd-offline-note">该任务已停用：不会被推荐、轮换到；历史记录与已激活任务不受影响。</div>';
        }
        html += '<div class="sqd-sub">' + esc(quest.subtitle) + '</div>';
        html += '<h3>步骤</h3><ol class="sqd-steps">';
        (quest.steps || []).forEach(function (step) {
            html += '<li>' + esc(step) + '</li>';
        });
        html += '</ol>';
        html += '<h3>提示</h3><div class="sqd-sub">' + esc(quest.hint) + '</div>';
        var roleKeys = Object.keys(quest.roleHints || {});
        if (roleKeys.length) {
            html += '<h3>角色提示</h3><div class="sqd-roles">';
            roleKeys.forEach(function (role) {
                html += '<div><strong>' + esc(roles[role] || role) + '</strong>：' +
                        esc(quest.roleHints[role]) + '</div>';
            });
            html += '</div>';
        }
        html += '<h3>偏好标签</h3><div class="sqd-tags">';
        (quest.preferenceTags || []).forEach(function (tag) {
            html += '<span>' + esc(tag) + '</span>';
        });
        html += '</div>';
        var view = byId('sq-drawer-view');
        if (view) {
            view.innerHTML = html;
        }
    }

    function formEl(name) {
        return document.querySelector('#sq-drawer-form [name="' + name + '"]');
    }

    function setField(name, value) {
        var el = formEl(name);
        if (!el) {
            return;
        }
        if (el.type === 'checkbox' || el.type === 'radio') {
            el.checked = value === true || el.value === value;
        } else {
            el.value = value == null ? '' : value;
        }
    }

    function setTags(tags) {
        var list = tags || [];
        var boxes = document.querySelectorAll('#sq-drawer-form [name="preference_tags"]');
        for (var i = 0; i < boxes.length; i++) {
            boxes[i].checked = list.indexOf(boxes[i].value) !== -1;
        }
    }

    function clearForm() {
        var form = byId('sq-drawer-form');
        if (!form) {
            return;
        }
        var inputs = form.querySelectorAll('input[type=text], input[type=number], textarea');
        for (var i = 0; i < inputs.length; i++) {
            var name = inputs[i].name;
            if (name !== 'csrfmiddlewaretoken' && name !== 'q' && name !== 'page') {
                inputs[i].value = '';
            }
        }
        var boxes = form.querySelectorAll('input[type=checkbox]');
        for (var j = 0; j < boxes.length; j++) {
            boxes[j].checked = false;
        }
        var select = form.querySelector('select[name="category"]');
        if (select) {
            select.selectedIndex = 0;
        }
        var idInput = formEl('quest_id');
        if (idInput) {
            idInput.readOnly = false;
        }
    }

    function editUrl(id) {
        var d = drawer();
        var template = d ? d.getAttribute('data-edit-template') : '';
        return template.replace('__ID__', encodeURIComponent(id));
    }

    function openAdd() {
        var form = byId('sq-drawer-form');
        if (!form) {
            return;
        }
        hidePreview();
        clearForm();
        setField('enabled', true);
        form.action = drawer().getAttribute('data-add-url');
        heading('新增探索任务');
        showForm();
        openShell('add', '');
    }

    function openEdit(quest) {
        var form = byId('sq-drawer-form');
        if (!form || !quest) {
            return;
        }
        hidePreview();
        clearForm();
        var idInput = formEl('quest_id');
        setField('quest_id', quest.id);
        if (idInput) {
            idInput.readOnly = true;
        }
        setField('title', quest.title);
        setField('subtitle', quest.subtitle);
        setField('category', quest.category);
        setField('minutes', quest.minutes);
        setField('step_1', (quest.steps || [])[0] || '');
        setField('step_2', (quest.steps || [])[1] || '');
        setField('step_3', (quest.steps || [])[2] || '');
        setField('hint', quest.hint);
        setField('enabled', quest.enabled !== false);
        Object.keys(rolesData || {}).forEach(function (role) {
            setField('role_' + role, (quest.roleHints || {})[role] || '');
        });
        setTags(quest.preferenceTags);
        form.action = editUrl(quest.id);
        heading('编辑 · ' + quest.id);
        showForm();
        openShell('edit', quest.id);
    }

    function configureQuick(quest) {
        var index = -1;
        for (var i = 0; i < questsData.length; i++) {
            if (questsData[i].id === quest.id) {
                index = i;
            }
        }
        var locked = originalCount > 0 && index >= 0 && index + 1 <= originalCount;
        var enabled = quest.enabled !== false;
        var toggle = byId('sqd-toggle-btn');
        if (toggle) {
            toggle.textContent = enabled ? '停用此任务' : '重新启用';
        }
        var up = byId('sqd-move-up');
        var down = byId('sqd-move-down');
        if (up) { up.style.display = locked ? 'none' : ''; }
        if (down) { down.style.display = locked ? 'none' : ''; }
        var note = byId('sqd-locked-note');
        if (note) { note.style.display = locked ? '' : 'none'; }
    }

    function submitQuick(url, dir) {
        var form = byId('sqd-quick-form');
        if (!form || !url) {
            return;
        }
        form.action = url;
        var dirInput = form.querySelector('[name="dir"]');
        if (dirInput) {
            dirInput.value = dir || '';
        }
        form.submit();
    }

    function openView(id) {
        var quest = findQuest(id);
        if (!quest) {
            return;
        }
        hidePreview();
        renderView(quest);
        configureQuick(quest);
        var editBtn = byId('sq-drawer-edit-btn');
        if (editBtn) {
            editBtn.setAttribute('data-sq-id', id);
        }
        heading(quest.title);
        showView();
        openShell('view', id);
    }

    document.addEventListener('click', function (event) {
        var target = event.target;
        var anchor = target.closest ? target.closest('[data-sq-drawer]') : null;
        if (anchor) {
            event.preventDefault();
            var mode = anchor.getAttribute('data-sq-drawer');
            var id = anchor.getAttribute('data-sq-id') || '';
            if (mode === 'view') {
                openView(id);
            } else if (mode === 'edit') {
                openEdit(findQuest(id));
            } else {
                openAdd();
            }
            return;
        }

        var quick = target.closest ? target.closest('[data-sq-quick]') : null;
        if (quick) {
            var d = drawer();
            if (!d) {
                return;
            }
            var quickId = d.dataset.id || '';
            var quest = findQuest(quickId);
            if (!quest) {
                return;
            }
            var action = quick.getAttribute('data-sq-quick');
            if (action === 'toggle') {
                var message = quest.enabled !== false
                    ? '确定停用「' + quest.title + '」？停用后不再被推荐，历史记录与已激活任务不受影响。'
                    : '确定重新启用「' + quest.title + '」？';
                if (!window.confirm(message)) {
                    return;
                }
                submitQuick((d.getAttribute('data-toggle-template') || '').replace('__ID__', encodeURIComponent(quickId)), '');
            } else if (action === 'move-up' || action === 'move-down') {
                submitQuick(
                    (d.getAttribute('data-move-template') || '').replace('__ID__', encodeURIComponent(quickId)),
                    action === 'move-up' ? 'up' : 'down'
                );
            }
            return;
        }

        if (target.closest && target.closest('[data-sq-preview-back]')) {
            hidePreview();
            showForm();
            return;
        }

        if (target.closest && target.closest('[data-sq-preview-confirm]')) {
            skipPreview = true;
            var form = byId('sq-drawer-form');
            if (form) {
                form.submit();
            }
            return;
        }

        if (target.closest('#sq-drawer-backdrop') || target.closest('[data-sq-close]')) {
            closeDrawer();
        }
    });

    document.addEventListener('keydown', function (event) {
        if (event.key === 'Escape') {
            closeDrawer();
        }
    });

    function onFormSubmit(event) {
        if (skipPreview) {
            return;
        }
        event.preventDefault();
        var form = byId('sq-drawer-form');
        var d = drawer();
        var mode = d ? d.dataset.open : '';
        var id = d ? d.dataset.id : '';
        var html = window.SqQuestDiff && mode !== 'view'
            ? window.SqQuestDiff.render(questsData, mode, id, form, rolesData)
            : null;
        if (!html) {
            skipPreview = true;
            form.submit();
            return;
        }
        var panel = preview();
        panel.innerHTML = '<div class="sqd-preview-head">保存前确认' +
            (mode === 'edit' ? '：将修改「' + esc(id) + '」' : '：将新增一条任务') + '</div>' +
            html +
            '<div class="sqd-actions">' +
            '<button type="button" class="sqd-btn ghost" data-sq-preview-back>返回修改</button>' +
            '<button type="button" class="sqd-btn" data-sq-preview-confirm>确认保存</button>' +
            '</div>';
        panel.style.display = '';
        form.style.display = 'none';
    }

    function init() {
        questsData = readJSON('sq-quests-data') || [];
        rolesData = readJSON('sq-roles-data') || {};
        var d = drawer();
        if (!d) {
            return;
        }
        originalCount = parseInt(d.getAttribute('data-original-count') || '0', 10) || 0;
        var form = byId('sq-drawer-form');
        if (form) {
            form.addEventListener('submit', onFormSubmit);
        }
        var mode = d.getAttribute('data-open') || '';
        var id = d.getAttribute('data-id') || '';
        if (!mode) {
            return;
        }
        if (d.getAttribute('data-form-bound') === '1') {
            // 服务端渲染的表单（含校验错误/回填值）：直接原样打开
            heading(mode === 'edit' ? '编辑 · ' + id : '新增探索任务');
            if (mode === 'view') {
                openView(id);
            } else {
                showForm();
                openShell(mode, id);
            }
            return;
        }
        if (mode === 'view') {
            openView(id);
        } else if (mode === 'edit') {
            openEdit(findQuest(id));
        } else {
            openAdd();
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
