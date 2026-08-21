from django.shortcuts import render

# Create your views here.
from django.http import HttpResponse
from django.template import loader

def designWithCory(request):
  template = loader.get_template('landing.html')
  return HttpResponse(template.render())