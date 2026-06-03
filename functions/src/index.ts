import * as admin from "firebase-admin";

admin.initializeApp();

export {analyzeHearingAid} from "./analyzeHearingAid";
export {setUserRole} from "./setUserRole";
export {syncRoleClaim} from "./syncRoleClaim";
export {cascadeIncomingDelete} from "./cascadeIncomingDelete";
