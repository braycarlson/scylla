"""Views registering through the django-glue 0.x shortcut API.

Every call shape legacy django-glue callers write: aliased module import,
positional unique_name and target, a bare access string, a keyword
model_object, a from-import call, and a TemplateResponse whose template
arrives as the `template=` keyword.
"""
import django_glue as dg
from django.template.response import TemplateResponse
from django_glue import glue_function

from catalog.models import Product


def legacy_detail(request, pk):
    product = Product.objects.get(pk=pk)

    dg.glue_model_object(request, 'legacy_product', product)
    dg.glue_model_object(request, 'legacy_product_view', product, 'view')
    dg.glue_model_object(request, 'legacy_keyword', model_object=product)
    dg.glue_query_set(request, 'legacy_products', Product.objects.all(), 'view')
    dg.glue_template(request, 'legacy_row', 'catalog/partial/row.html')
    glue_function(request, 'legacy_report', 'catalog.views.list_view')

    return TemplateResponse(
        request,
        context={'product': product},
        template='catalog/legacy.html',
    )
