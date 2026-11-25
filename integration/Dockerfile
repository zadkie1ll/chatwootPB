ARG PYTHON_IMAGE
FROM ${PYTHON_IMAGE}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.lock ./
RUN pip install --no-cache-dir --require-hashes -r requirements.lock
COPY config ./config
COPY delivery ./delivery
COPY crm ./crm
COPY manage.py ./
USER 10001:10001
CMD ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8090", "--workers", "2", "--timeout", "45", "--no-control-socket", "--error-logfile", "-", "--access-logfile", "/dev/null"]
