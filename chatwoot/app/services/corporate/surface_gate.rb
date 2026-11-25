# Blocks alternate APIs and public signed downloads before Rails routing.
class Corporate::SurfaceGate
  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless Corporate.enabled?

    route = env['PATH_INFO']
    method = env['REQUEST_METHOD']
    allowed = route.start_with?('/internal/corporate/') || route == '/health' || route == '/' || route.start_with?('/app', '/vite/', '/assets/',
                                                                                                                   '/brand-assets/') ||
              route.start_with?('/auth/') || route.match?(%r{\A/api/v1/accounts/\d+(?:/|\z)}) ||
              route.match?(%r{\A/api/v1/profile(?:/|\z)}) || route.start_with?('/api/v1/corporate_files/') || route == '/cable' ||
              (method == 'PUT' && route.start_with?('/rails/active_storage/disk/'))
    return @app.call(env) if allowed

    [404, { 'content-type' => 'application/json', 'cache-control' => 'no-store' }, ['{"error":"Not found"}']]
  end
end
