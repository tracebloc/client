pod_details = api.list_namespaced_custom_object(
    group="metrics.k8s.io",
    version="v1beta1",
    namespace="tracebloc-templates",
    plural="pods",
    field_selector=f"metadata.name=mysql-79fbd58586-fdnh7",
)