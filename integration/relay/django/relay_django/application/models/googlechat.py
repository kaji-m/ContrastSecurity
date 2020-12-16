from django.db import models
from django.core.validators import RegexValidator
from django.utils.translation import gettext_lazy as _

class GoogleChat(models.Model):
    name = models.CharField(_('Name'), max_length=20, unique=True,
        validators=[RegexValidator(regex='^[A-Za-z0-9_]{4,20}$', message='名前は半角英数字、アンスコ4文字〜20文字です。')]
    )   
    webhook = models.URLField(_('Webhook'), help_text='https://chat.googleapis.com/v1/spaces/XXXXX/messages?key=YYYYY&token=ZZZZZ')

    def __str__(self):
        return '%s' % (self.name)

    class Meta:
        verbose_name = _('GoogleChat')
        verbose_name_plural = _('GoogleChat List')

