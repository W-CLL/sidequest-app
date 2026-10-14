from django.contrib import admin
from django.urls import path
from django.views.generic import RedirectView

from panel.views import media_file, media_thumb

urlpatterns = [
    path('', RedirectView.as_view(url='/admin/', permanent=False)),
    path('admin/', admin.site.urls),
    path('media-thumb/<str:media_id>/', media_thumb, name='media-thumb'),
    path('media-file/<str:media_id>/', media_file, name='media-file'),
]
