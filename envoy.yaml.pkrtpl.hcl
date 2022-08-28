static_resources:
  listeners:
    - name: main_listener
      address:
        socket_address:
            address: 0.0.0.0
            port_value: 443
      filter_chains:
        - filters:
          - name: envoy.filters.network.http_connection_manager
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
              stat_prefix: ingress_http
              server_name: lab.wansho.fr
              preserve_external_request_id: true
              access_log:
                - name: envoy.access_loggers.stdout
                  typed_config:
                    "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
              http_filters:
                - name: envoy.filters.http.router
                  typed_config:
                    "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
              route_config:
                name: local_route
                virtual_hosts:
                  - name: local_service
                    domains: ["*"]
                    require_tls: ALL
                    cors:
                      allow_methods: 'OPTION, GET'
                    routes:
                      - match:
                          prefix: "/"
                        route:
                          cluster: service_workstation
                          cluster_not_found_response_code: SERVICE_UNAVAILABLE
          transport_socket:
            name: envoy.transport_sockets.tls
            typed_config:
                "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
                common_tls_context:
                  alpn_protocols: ["h2"]
                  tls_certificates:
                      - certificate_chain:
                          filename: ${SERVER_CERT_PATH}
                        private_key:
                          filename: ${SERVER_KEY_PATH}
  clusters:
    - name: service_workstation
      type: LOGICAL_DNS
      # Comment out the following line to test on v6 networks
      dns_lookup_family: V4_ONLY
      lb_policy: ROUND_ROBIN
      load_assignment:
        cluster_name: service_workstation
        endpoints:
        - lb_endpoints:
            - endpoint:
                address:
                    socket_address:
                      address: 127.0.0.1
                      port_value: 80