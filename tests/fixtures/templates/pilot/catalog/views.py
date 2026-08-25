from django.http import HttpRequest, HttpResponse
from django.shortcuts import get_object_or_404, render

from django_glue import Glue

from catalog.forms import ProductForm
from catalog.models import Product


def list_view(request: HttpRequest) -> HttpResponse:
    Glue.queryset(
        request=request,
        unique_name='products',
        target=Product.objects.all(),
        access=Glue.Access.VIEW,
        fields=['id', 'is_active', 'name', 'price', 'sku'],
    )

    Glue.json(
        request=request,
        unique_name='page_size',
        target=25,
    )

    return render(request, 'catalog/list.html')


def detail_view(request: HttpRequest, pk: int) -> HttpResponse:
    product = get_object_or_404(Product, pk=pk)

    Glue.model(
        request=request,
        unique_name='product',
        target=product,
        access=Glue.Access.CHANGE,
        fields=['description', 'is_active', 'name', 'price', 'sku'],
    )

    Glue.form(
        request=request,
        unique_name='product_form',
        target=ProductForm(instance=product),
        access=Glue.Access.CHANGE,
    )

    Glue.template(
        request=request,
        unique_name='product_row',
        target='catalog/partial/row.html',
    )

    Glue.function(
        request=request,
        unique_name='restock',
        target='catalog.services.restock',
    )

    return render(request, 'catalog/detail.html')
