"""把 Django 后台自身的数据路由到独立的 admin.sqlite，业务库保持纯净。"""

DJANGO_APPS = frozenset({'admin', 'auth', 'contenttypes', 'sessions'})


class AdminDatabaseRouter:
    def _route(self, model):
        if model._meta.app_label in DJANGO_APPS:
            return 'django'
        return 'default'

    def db_for_read(self, model, **hints):
        return self._route(model)

    def db_for_write(self, model, **hints):
        return self._route(model)

    def allow_relation(self, obj1, obj2, **hints):
        # 同库内的关联放行；跨库关联不存在于现有模型中。
        return obj1._state.db == obj2._state.db

    def allow_migrate(self, db, app_label, **hints):
        if app_label in DJANGO_APPS:
            return db == 'django'
        # panel 的模型全部 managed=False，不会产生任何迁移。
        return False
