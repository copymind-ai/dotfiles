import { EdgeWorker } from "@pgflow/edge-worker";
import { __FLOW_EXPORT__ } from "../../flows/__KEBAB_SLUG__.ts";

EdgeWorker.start(__FLOW_EXPORT__);
