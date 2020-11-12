{%- from "hana/map.jinja" import hana with context -%}
{%- from 'hana/macros/get_hana_exe_extract_dir.sls' import get_hana_exe_extract_dir with context %}
# If hana archive used for installation is sar format, it will not contain the hana client, so we need to use a hana client archive
{%- if hana.hana_client_archive_file is defined and hana.hana_archive_file is defined and hana.hana_archive_file.endswith((".sar", ".SAR")) %}
{%- set hana_client_path = hana.hana_client_extract_dir %}
{%- else %}
{%- set hana_client_path = get_hana_exe_extract_dir(hana) %}
{%- endif %}

{% set pydbapi_output_dir = '/tmp/pydbapi' %}

{% for node in hana.nodes if node.host == grains['host'] %}

# if we have a replicated setup we only take exporter configuration from the primary
{% if node.secondary is not defined %}
{% set exporter = node.exporter|default(None) %}
{% else %}
{% set primary = (hana.nodes|selectattr("host", "equalto", node.secondary.remote_host)|selectattr("primary", "defined")|first) %}
{% set exporter = primary.exporter|default(None) %}
{% endif %}

{% if exporter is not none %}

{% set sap_instance_nr = '{:0>2}'.format(node.instance) %}
{% set exporter_instance = '{}_HDB{}'.format(node.sid.upper(), sap_instance_nr) %}

{% if loop.first %}
install_python_pip:
  pkg.installed:
    - name: python3-pip
    - retry:
        attempts: 3
        interval: 15
    - resolve_capabilities: true

extract_pydbapi_client:
  hana.pydbapi_extracted:
    - name: PYDBAPI.TGZ
    - software_folders: [{{ exporter.hana_client_path|default(node.install.software_path)|default(hana.software_path)|default(hana_client_path) }}]
    - output_dir: {{ pydbapi_output_dir }}
    - hana_version: '20'
    - force: true

# pip.installed cannot manage file names with regular expressions
# TODO: Improve this to use pip.installed somehow
install_pydbapi_client:
  cmd.run:
    - name: /usr/bin/python3 -m pip install {{ pydbapi_output_dir }}/hdbcli-*.tar.gz
    - require:
      - install_python_pip
      - extract_pydbapi_client

prometheus-hanadb_exporter:
  pkg.installed:
  - retry:
      attempts: 3
      interval: 15
  - require:
      - install_pydbapi_client

{% endif %}

hanadb_exporter_configuration_{{ exporter_instance }}:
  file.managed:
    - source: salt://hana/templates/hanadb_exporter.j2
    - name: /usr/etc/hanadb_exporter/{{ exporter_instance }}.json
    - template: jinja
    - require:
      - prometheus-hanadb_exporter
    - context:
        exporter: {{ exporter|yaml }}
        sap_instance_nr: "{{ sap_instance_nr }}"
        exporter_instance: {{ exporter_instance }}

{% if hana.ha_enabled %}
{% set service_status = "disabled" %}
{% set service_enabled = False %}
{% else %}
{% set service_status = "running" %}
{% set service_enabled = True %}
{% endif %}

hanadb_exporter_service_{{ exporter_instance }}:
  service.{{ service_status }}:
    - name: prometheus-hanadb_exporter@{{ exporter_instance }}
    - enable: {{ service_enabled }}
    - reload: True
    - require:
        - hanadb_exporter_configuration_{{ exporter_instance }}

{% endif %}
{% endfor %}
