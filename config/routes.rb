SuperAuth::Engine.routes.draw do
  get '/graph', to: 'graph#index'
  get '/graph/authorize', to: 'graph#authorize'
  get '/visualization', to: 'graph#visualization'
end
