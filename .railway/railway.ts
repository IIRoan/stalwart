import {
  bucket,
  defineRailway,
  github,
  group,
  postgres,
  project,
  service,
  volume,
} from "railway/iac";

// Named partial: this repo is not the whole Rocal project (Solace apps live elsewhere).
export const partial = "stalwart";

const volumeAlerts = {
  alerts: { usage: { "80": {}, "95": {}, "100": {} } },
  allowOnlineResize: true,
  region: "europe-west4-drams3a",
  sizeMB: 5000,
} as const;

export default defineRailway(() => {
  const db = postgres("Postgres-stalwart", { region: "europe-west4-drams3a" });
  const dbVolume = volume("postgres-stalwart", volumeAlerts);
  const monitoringVolume = volume("monitoring-volume", volumeAlerts);
  const blobs = bucket("stalwart-blobs", { region: "ams" });

  const mail = service("stalwart-mail", {
    source: github("IIRoan/stalwart", { checkSuites: false }),
    build: {
      builder: "DOCKERFILE",
      dockerfilePath: "Dockerfile",
      buildEnvironment: "V3",
    },
    healthcheck: "/healthz/ready",
    healthcheckTimeout: 300,
    replicas: { "europe-west4-drams3a": 1 },
    deploy: {
      ipv6EgressEnabled: true,
      overlapSeconds: 90,
      drainingSeconds: 120,
    },
    networking: { privateNetworkEndpoint: "stalwart" },
  });

  const monitoring = service("Monitoring", {
    source: github("IIRoan/stalwart", {
      rootDirectory: "gatus",
      checkSuites: false,
    }),
    build: {
      builder: "DOCKERFILE",
      dockerfilePath: "Dockerfile",
      buildEnvironment: "V3",
    },
    healthcheck: "/health",
    replicas: { "europe-west4-drams3a": 1 },
    deploy: {
      restartPolicyType: "ON_FAILURE",
      restartPolicyMaxRetries: 3,
    },
    domains: ["status.solace.onl"],
    networking: { privateNetworkEndpoint: "monitoring" },
    volumeMounts: {
      "/data": monitoringVolume,
    },
  });

  const mailServer = group("Mail server", [mail, db]);

  return project("Rocal", {
    resources: [
      mail,
      monitoring,
      db,
      dbVolume,
      monitoringVolume,
      blobs,
      mailServer,
    ],
  });
});
