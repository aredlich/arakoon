import os
import os.path
import logging

import xml.xpath
import xml.dom.minidom

import jinja2

import docutils
import docutils.core

import feedparser

URI = 'http://blog.incubaid.com/category/arakoon/feed/'
ENCODING = 'utf-8'
FILTER = lambda f: \
    (f.endswith('.html') or f.endswith('.rst')) \
    and not (f.startswith('_'))

RST_SETTINGS = {
    'initial_header_level': 2,
}
RST_TEMPLATE = u'''
{%% extends '_base.html' %%}
{%% block title %%}%(title)s{%% endblock %%}
{%% block main %%}
%(main)s
{%% endblock %%}
'''

LOGGER = logging.getLogger(__name__)

def render_rst(in_, out):
    fd = open(in_, 'r') # Will be closed by docutils

    text, doc = docutils.core.publish_programmatically(
        source_class=docutils.io.FileInput, source=fd, source_path=in_,
        destination_class=docutils.io.StringOutput, destination=None,
        destination_path=None,
        reader=None, reader_name='standalone',
        parser=None, parser_name='restructuredtext',
        writer=None, writer_name='html',
        settings=None, settings_spec=None, settings_overrides=RST_SETTINGS,
        config_section=None, enable_exit_status=False)

    title = doc.document['title']

    body = xml.xpath.Evaluate(
        '/html/body/div[@class=\'document\']',
        xml.dom.minidom.parseString(text).documentElement)[0]
    body_html = body.toxml()

    template = RST_TEMPLATE % {
        'title': title,
        'main': body_html,
    }

    data = template.encode('utf-8')
    fd_out = open(out, 'w')
    try:
        fd_out.write(data)
    finally:
        fd_out.close()

def run(src, target):
    LOGGER.info('Rendering %s to %s', src, target)

    context = {}

    feed = feedparser.parse(URI)
    context['feed'] = feed

    loader = jinja2.FileSystemLoader((src, ))
    environment = jinja2.Environment(
        loader=loader, undefined=jinja2.StrictUndefined)

    for name in filter(FILTER, os.listdir(src)):
        LOGGER.debug('Rendering %s', name)

        cleanup_html = False
        html_file = None

        template_name = name

        if name.endswith('.rst'):
            cleanup_html = True

            basename = name[:-4]
            template_name = '%s.html' % basename
            html_file = os.path.join(src, template_name)
            assert not os.path.exists(html_file)

            render_rst(os.path.join(src, name), html_file)

        try:
            template = environment.get_template(template_name)

            local_context = context.copy()
            local_context['name'] = os.path.splitext(template_name)[0]

            output = template.render(local_context)
            output_str = output.encode(ENCODING)

            out = os.path.join(target, template_name)
            fd = open(out, 'w')
            try:
                LOGGER.debug('Writing to %s', out)

                fd.write(output_str)
            finally:
                fd.close()
        finally:
            if cleanup_html:
                os.unlink(html_file)

def main():
    src = os.path.abspath(os.path.dirname(__file__))
    target = os.path.abspath(os.path.join(src, os.path.pardir))

    run(src, target)

if __name__ == '__main__':
    main()
