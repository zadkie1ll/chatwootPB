# Blocks alternate APIs and public signed downloads before Rails routing.
class Corporate::SurfaceGate
  PUBLIC_PREFIXES = %w[/internal/corporate/ /app /vite/ /assets/ /brand-assets/ /auth/ /api/v1/corporate_files/].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless Corporate.enabled?
    return @app.call(env) if allowed?(env['PATH_INFO'], env['REQUEST_METHOD'])

    [404, { 'content-type' => 'application/json', 'cache-control' => 'no-store' }, ['{"error":"Not found"}']]
  end

  private

  def allowed?(route, method)
    public_route?(route) || account_api?(route) || push_route?(route, method) ||
      (method == 'PUT' && route.start_with?('/rails/active_storage/disk/'))
  end

  def public_route?(route)
    %w[/health / /cable].include?(route) || route.start_with?(*PUBLIC_PREFIXES)
  end

  def account_api?(route)
    route.match?(%r{\A/api/v1/accounts/\d+(?:/|\z)}) || route.match?(%r{\A/api/v1/profile(?:/|\z)})
  end

  def push_route?(route, method)
    (route == '/sw.js' && %w[GET HEAD].include?(method)) || (route == '/api/v1/corporate_push_receipts' && method == 'POST')
  end
end
