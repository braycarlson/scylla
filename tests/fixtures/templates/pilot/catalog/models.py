from django.db import models


class Category(models.Model):
    name = models.CharField(max_length=64)
    slug = models.SlugField(unique=True)

    def __str__(self) -> str:
        return self.name


class TimeStamped(models.Model):
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True


class Product(TimeStamped):
    category = models.ForeignKey(Category, on_delete=models.CASCADE, related_name='products')
    description = models.TextField(blank=True)
    is_active = models.BooleanField(default=True)
    name = models.CharField(max_length=128)
    price = models.DecimalField(decimal_places=2, max_digits=10)
    signature = models.BinaryField(default=b'')
    sku = models.CharField(max_length=32, unique=True)

    def __str__(self) -> str:
        return self.name
