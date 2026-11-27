using System.Collections.Generic;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEngine;

namespace DynamicRagdoll
{
    public class RagdollSetupWindow : EditorWindow
    {
        private GameObject character;

        private Transform hips;
        private Transform leftThigh;
        private Transform leftKnee;
        private Transform leftFoot;
        private Transform leftToe;
        private Transform rightThigh;
        private Transform rightKnee;
        private Transform rightFoot;
        private Transform rightToe;
        private Transform leftScapula;
        private Transform leftArm;
        private Transform leftElbow;
        private Transform leftHand;
        private Transform rightScapula;
        private Transform rightArm;
        private Transform rightElbow;
        private Transform rightHand;
        private Transform Spine1;
        private Transform middleSpine;
        private Transform Spine3;
        private Transform neck;
        private Transform head;

        private float totalMass = 80;

        private int rightAxis;
        private int upAxis;
        private int fwdAxis;

        private DynamicBehaviour D_behaviour;
        private BOS D_bos;
        private HipsDrive D_hipsDrive;
        private RagdollManager D_ragdollManager;
        private InverseDynamic D_leftLeg;
        private InverseDynamic D_rightLeg;
        private InverseDynamic D_leftArm;
        private InverseDynamic D_rightArm;
        private HandsDrive D_handsDrive;

        private int L_legPole;
        private int L_legDir;
        private int L_legUp;

        private int R_legPole;
        private int R_legDir;
        private int R_legUp;

        private int L_armPole;
        private int L_armDir;
        private int L_armUp;

        private int R_armPole;
        private int R_armDir;
        private int R_armUp;

        private int RTUp;
        private int LTUp;

        private List<RagdollManager.JointSpringInfo> _jointSpringList;

        private HashSet<Transform> autoAssignedTransforms = new HashSet<Transform>();

        private static readonly string[] boneExcludeKeywords = new string[]
        {
            "ik", "ctrl", "control", "hint", "guide",
            "pole", "effector", "target", "proxy", "ref",
            "helper", "guide", "dummy", "handle", "gizmo"
        };

        [MenuItem("Tools/Dynamic Ragdoll Setup ")]
        public static void ShowWindow()
        {
            RagdollSetupWindow window = GetWindow<RagdollSetupWindow>("Dynamic Ragdoll Setup");
            window.minSize = new Vector2(350, 680);  
            window.maxSize = new Vector2(350, 680);
        }

        private void OnGUI()
        {
            GUIStyle descriptionStyle = new GUIStyle(EditorStyles.boldLabel);
            descriptionStyle.fontSize = 12;
            descriptionStyle.wordWrap = true;

            EditorGUILayout.LabelField(
                "Please place all bones in the boxes." +
                "\nMake sure the character is in T-stand and standing upright, facing in the direction of Vector3.up",
                descriptionStyle
                );
            
            GUILayout.Space(10);

            character = (GameObject)EditorGUILayout.ObjectField("Character", character, typeof(GameObject), true);
            hips = DrawBoneField("Hips", hips);
            leftThigh = DrawBoneField("Left Thigh (Leg,Hip_L)", leftThigh);
            leftKnee = DrawBoneField("Left Knee", leftKnee);
            leftFoot = DrawBoneField("Left Foot", leftFoot);
            leftToe = DrawBoneField("Left Toe", leftToe);
            rightThigh = DrawBoneField("Right Thigh (Leg,Hip_R)", rightThigh);
            rightKnee = DrawBoneField("Right Knee", rightKnee);
            rightFoot = DrawBoneField("Right Foot", rightFoot);
            rightToe = DrawBoneField("Right Toe", rightToe);
            leftScapula = DrawBoneField("Left Scapula (Clavicle)", leftScapula);
            leftArm = DrawBoneField("Left Arm", leftArm);
            leftElbow = DrawBoneField("Left Elbow", leftElbow);
            leftHand = DrawBoneField("Left Hand", leftHand);
            rightScapula = DrawBoneField("Right Scapula (Clavicle)", rightScapula);
            rightArm = DrawBoneField("Right Arm", rightArm);
            rightElbow = DrawBoneField("Right Elbow", rightElbow);
            rightHand = DrawBoneField("Right Hand", rightHand);
            Spine1 = DrawBoneField("Spine1", Spine1);
            middleSpine = DrawBoneField("Middle Spine (Spine2)", middleSpine);
            Spine3 = DrawBoneField("Spine3 (Chest)", Spine3);
            neck = DrawBoneField("Neck", neck);
            head = DrawBoneField("Head", head);
            totalMass = (float)EditorGUILayout.FloatField("Total Mass", totalMass);

            GUILayout.Space(5);

            if (GUILayout.Button("Auto Assign Bones", GUILayout.Height(25)))
            {
                AutoAssignBones();
            }

            EditorGUILayout.HelpBox(
                "After auto assigning, please double-check all fields. " +
                "Some bones may be assigned incorrectly or left empty.",
                MessageType.Warning
            );

            GUILayout.Space(10);

            if (GUILayout.Button("Create Dynamic Ragdoll", GUILayout.Height(40)))
            {
                if (CreateRagdoll()) 
                {
                    EditorUtility.DisplayDialog("Dynamic Ragdoll setup is successful.", "You must set your fixed timestep value to 0.005. Otherwise, the package will not perform as expected !", "Okay");
                    Close();
                }
                else
                {
                    EditorUtility.DisplayDialog("Failed", "All body parts must be assigned!", "Okay");
                }
            }

        }

        private void AutoAssignBones()
        {
            if (character == null)
            {
                EditorUtility.DisplayDialog("Warning", "Please assign 'Character' first!", "Okay");
                return;
            }

            Transform[] allTransforms = character.GetComponentsInChildren<Transform>(true);
            HashSet<Transform> assigned = new HashSet<Transform>();
            autoAssignedTransforms.Clear();

            // Önce hips aranır — "root" bazı riglerde pelvis ismidir
            hips       = FindAndMark(assigned, allTransforms, "hips", "pelvis", "root");

            // Bacaklar
            leftThigh  = FindSideAndMark(assigned, allTransforms, true, "thigh", "upleg", "hip", "upperleg");
            leftKnee   = FindSideAndMark(assigned, allTransforms, true, "knee", "shin", "calf", "lowerleg", "leg");
            leftFoot   = FindSideAndMark(assigned, allTransforms, true, "foot", "ankle");
            leftToe    = FindSideAndMark(assigned, allTransforms, true, "toe", "ball");
            rightThigh = FindSideAndMark(assigned, allTransforms, false, "thigh", "upleg", "hip", "upperleg");
            rightKnee  = FindSideAndMark(assigned, allTransforms, false, "knee", "shin", "calf", "lowerleg", "leg");
            rightFoot  = FindSideAndMark(assigned, allTransforms, false, "foot", "ankle");
            rightToe   = FindSideAndMark(assigned, allTransforms, false, "toe", "ball");

            // Kollar
            leftScapula   = FindSideAndMark(assigned, allTransforms, true, "scapula", "clavicle", "shoulder", "collar");
            leftArm       = FindSideAndMark(assigned, allTransforms, true, "arm", "upperarm", "shoulder");
            leftElbow     = FindSideAndMark(assigned, allTransforms, true, "elbow", "forearm", "lowerarm");
            leftHand      = FindSideAndMark(assigned, allTransforms, true, "hand", "wrist");

            rightScapula  = FindSideAndMark(assigned, allTransforms, false, "scapula", "clavicle", "shoulder", "collar");
            rightArm      = FindSideAndMark(assigned, allTransforms, false, "arm", "upperarm", "shoulder");
            rightElbow    = FindSideAndMark(assigned, allTransforms, false, "elbow", "forearm", "lowerarm");
            rightHand     = FindSideAndMark(assigned, allTransforms, false, "hand", "wrist");

            // Omurga — hips ("spine") assigned'a eklendiği için burada atlanır
            Spine1       = FindSpineAndMark(assigned, allTransforms, 1, "spine1", "spine_1", "spine_01", "spine01");
            middleSpine  = FindSpineAndMark(assigned, allTransforms, 2, "spine2", "spine_2", "spine_02", "spine02", "middlespine");
            Spine3       = FindSpineAndMark(assigned, allTransforms, 3, "spine3", "spine_3", "spine_03", "spine03", "chest", "upperchest");
            neck         = FindAndMark(assigned, allTransforms, "neck");
            head         = FindAndMark(assigned, allTransforms, "head");

            autoAssignedTransforms.UnionWith(assigned);

            Repaint();
        }

        // "LeftUpLeg", "mixamorig:LeftUpLeg", "LUpLeg" gibi delimiter içermeyen
        // camelCase/prefix isimlerde de kelime sınırı bulabilmek için kullanılır.
        private static readonly Regex CamelCaseBoundary =
            new Regex(@"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", RegexOptions.Compiled);

        private string[] TokenizeBoneName(string name)
        {
            string withBoundaries = CamelCaseBoundary.Replace(name, "_");
            return withBoundaries.Split('_', '.', ' ', ':', '-');
        }

        private bool HasLeftIndicator(string name)
        {
            foreach (var token in TokenizeBoneName(name))
            {
                string t = token.ToLower();
                if (t == "l" || t == "left")
                    return true;
            }
            return false;
        }

        private bool HasRightIndicator(string name)
        {
            foreach (var token in TokenizeBoneName(name))
            {
                string t = token.ToLower();
                if (t == "r" || t == "right")
                    return true;
            }
            return false;
        }

        private Transform FindSideBone(HashSet<Transform> exclude, Transform[] transforms, bool isLeft, params string[] keywords)
        {
            List<Transform> candidates = new List<Transform>();

            foreach (var t in transforms)
            {
                if (exclude.Contains(t))
                    continue;

                string tName = t.name.Replace(" ", "_").ToLower();

                if (IsExcludedName(tName))
                    continue;

                bool sideMatch = isLeft ? HasLeftIndicator(t.name) : HasRightIndicator(t.name);
                if (!sideMatch)
                    continue;

                foreach (var kw in keywords)
                {
                    if (tName.Contains(kw.ToLower()))
                    {
                        candidates.Add(t);
                        break;
                    }
                }
            }

            return PickBestCandidate(candidates);
        }

        private Transform PickBestCandidate(List<Transform> candidates)
        {
            if (candidates == null || candidates.Count == 0)
                return null;
            if (candidates.Count == 1)
                return candidates[0];

            Transform best = candidates[0];
            int bestCount = best.GetComponentsInChildren<Transform>().Length;

            for (int i = 1; i < candidates.Count; i++)
            {
                int count = candidates[i].GetComponentsInChildren<Transform>().Length;
                if (count > bestCount)
                {
                    bestCount = count;
                    best = candidates[i];
                }
            }

            return best;
        }

        private Transform FindBone(HashSet<Transform> exclude, Transform[] transforms, params string[] keywords)
        {
            // Keyword'ler öncelik sırasına göre tek tek taranır: bir öncekiyle eşleşen
            // aday bulunursa sonraki (daha düşük öncelikli) keyword'lere hiç bakılmaz.
            // Bu sayede isim önceliği (örn. "hips" > "root"), child sayısından önce gelir.
            foreach (var kw in keywords)
            {
                string kwLower = kw.ToLower();
                List<Transform> candidates = new List<Transform>();

                foreach (var t in transforms)
                {
                    if (exclude.Contains(t))
                        continue;

                    string tName = t.name.Replace(" ", "_").ToLower();

                    if (IsExcludedName(tName))
                        continue;

                    if (tName.Contains(kwLower))
                        candidates.Add(t);
                }

                if (candidates.Count > 0)
                    return PickBestCandidate(candidates);
            }

            return null;
        }

        private Transform FindAndMark(HashSet<Transform> assigned, Transform[] transforms, params string[] keywords)
        {
            Transform result = FindBone(assigned, transforms, keywords);
            if (result != null)
                assigned.Add(result);
            return result;
        }

        private Transform FindSideAndMark(HashSet<Transform> assigned, Transform[] transforms, bool isLeft, params string[] keywords)
        {
            Transform result = FindSideBone(assigned, transforms, isLeft, keywords);
            if (result != null)
                assigned.Add(result);
            return result;
        }

        private Transform FindSpineBone(HashSet<Transform> exclude, Transform[] transforms, int index, params string[] keywords)
        {
            string numStr = index.ToString();
            List<Transform> candidates = new List<Transform>();

            foreach (var t in transforms)
            {
                if (exclude.Contains(t))
                    continue;

                string tName = t.name.Replace(" ", "_").ToLower();

                if (IsExcludedName(tName))
                    continue;

                bool match = false;

                foreach (var kw in keywords)
                {
                    if (tName.Contains(kw.ToLower()))
                    {
                        match = true;
                        break;
                    }
                }

                if (!match && tName.Contains("spine") && tName.Contains(numStr))
                    match = true;

                if (!match && index == 1 && tName.Equals("spine"))
                    match = true;

                if (!match && index == 3 && (tName.Contains("chest") || tName.Contains("upper")))
                    match = true;

                if (match)
                    candidates.Add(t);
            }

            return PickBestCandidate(candidates);
        }

        private Transform FindSpineAndMark(HashSet<Transform> assigned, Transform[] transforms, int index, params string[] keywords)
        {
            Transform result = FindSpineBone(assigned, transforms, index, keywords);
            if (result != null)
                assigned.Add(result);
            return result;
        }

        private bool IsExcludedName(string name)
        {
            foreach (var kw in boneExcludeKeywords)
            {
                if (name.Contains(kw))
                    return true;
            }
            return false;
        }

        private Transform DrawBoneField(string label, Transform currentValue)
        {
            Rect rect = EditorGUILayout.GetControlRect();

            if (currentValue != null && autoAssignedTransforms.Contains(currentValue))
            {
                EditorGUI.DrawRect(rect, new Color(0.3f, 0.8f, 0.3f, 0.25f));
            }

            return (Transform)EditorGUI.ObjectField(rect, label, currentValue, typeof(Transform), true);
        }

        private bool CreateRagdoll()
        {

            if (hips == null || leftThigh == null || leftKnee == null || leftFoot == null || leftToe == null || rightThigh == null || rightKnee == null || rightFoot == null
                || rightToe == null || rightKnee == null || leftArm == null || leftElbow == null || leftHand == null || rightArm == null || rightElbow == null || rightHand == null || middleSpine == null || head == null)
            {
                return false;
            }

            Debug.Log("Ragdoll setup started!");


            AddRigidbody(hips, "Hips");
            AddRigidbody(leftThigh, "LeftThigh");
            AddRigidbody(leftKnee, "LeftKnee");
            AddRigidbody(leftFoot, "LeftFoot");
            AddRigidbody(rightThigh, "RightThigh");
            AddRigidbody(rightKnee, "RightKnee");
            AddRigidbody(rightFoot, "RightFoot");
            AddRigidbody(leftArm, "LeftArm");
            AddRigidbody(leftElbow, "LeftElbow");
            AddRigidbody(rightArm, "RightArm");
            AddRigidbody(rightElbow, "RightElbow");
            AddRigidbody(middleSpine, "MiddleSpine");
            AddRigidbody(head, "Head");

            SetUpPelvisCollider(hips);
            SetUpLegCollider(leftThigh, leftKnee, leftFoot, leftToe, true);
            SetUpLegCollider(rightThigh, rightKnee, rightFoot, rightToe, false);
            SetUpArmCollider(leftArm, leftElbow, leftHand);
            SetUpArmCollider(rightArm, rightElbow, rightHand);
            SetUpHeadCollider(head);

            _jointSpringList = new List<RagdollManager.JointSpringInfo>();

            SetUpHipsJoint(hips);
            SetUpSpineJoint(middleSpine);
            SetUpHeadJoint(head);
            SetUpLegJoint(leftThigh, leftKnee, leftFoot, true);
            SetUpLegJoint(rightThigh, rightKnee, rightFoot, false);
            SetUpArmJoint(leftArm, leftElbow, true);
            SetUpArmJoint(rightArm, rightElbow, false);


            SetUpScripts();

            return true;
        }

        private void SetUpScripts()
        {
            GameObject dynamicRagdollBase = new GameObject("DYNAMICRAGDOLL_BEHAVIOUR");
            dynamicRagdollBase.transform.parent = character.transform;

            GameObject dynamicRagdollTools = new GameObject("DYNAMICRAGDOLL_TOOLS");
            dynamicRagdollTools.transform.parent = dynamicRagdollBase.transform;

            D_behaviour = dynamicRagdollBase.AddComponent<DynamicBehaviour>();
            D_bos = dynamicRagdollTools.AddComponent<BOS>();
            D_hipsDrive = dynamicRagdollTools.AddComponent<HipsDrive>();
            D_ragdollManager = dynamicRagdollTools.AddComponent<RagdollManager>();

            SetUpFootDet();
            SetUpBOS(D_bos);
            SetUpHipsDrive(D_hipsDrive);
            SetUpRagdollManager(D_ragdollManager);

            InverseDynamic Lleg = dynamicRagdollTools.AddComponent<InverseDynamic>();
            InverseDynamic Rleg = dynamicRagdollTools.AddComponent<InverseDynamic>();

            D_leftArm = dynamicRagdollTools.AddComponent<InverseDynamic>();
            D_rightArm = dynamicRagdollTools.AddComponent<InverseDynamic>();

            SetUpLeg(Lleg, true);
            SetUpLeg(Rleg, false);
            SetUpArm(D_leftArm, true);
            SetUpArm(D_rightArm, false);

            SetUpBehaviour(D_behaviour, Rleg, Lleg, D_rightArm, D_leftArm);

            D_handsDrive = dynamicRagdollTools.AddComponent<HandsDrive>();
            SetUpHandsDrive(D_handsDrive);
            D_behaviour.handsDrive = D_handsDrive;

            Debug.Log("Dynamic Ragdoll setup completed.");
        }

        private void SetUpHandsDrive(HandsDrive handsDrive)
        {
            float armLength = Vector3.Distance(leftArm.position, leftHand.position);

            Vector3 rightDir = hips.GetWorldDir(rightAxis);
            Vector3 fwdDir = hips.GetWorldDir(fwdAxis);

            Vector3 verticalOffset = Vector3.up * (armLength * 0.5f);

            GameObject handsTarget = new GameObject("HandsTarget");
            handsTarget.transform.parent = hips;
            handsTarget.transform.localPosition = Vector3.zero;
            handsTarget.hideFlags = HideFlags.HideInHierarchy;

            GameObject lhIdle = new GameObject("LH_Idle");
            lhIdle.transform.parent = handsTarget.transform;
            lhIdle.transform.position = hips.position + (-rightDir) * (armLength * 0.6f);

            GameObject lhSide = new GameObject("LH_Side");
            lhSide.transform.parent = handsTarget.transform;
            lhSide.transform.position = leftHand.position - rightDir * armLength + verticalOffset;

            GameObject lhFront = new GameObject("LH_Front");
            lhFront.transform.parent = handsTarget.transform;
            lhFront.transform.position = lhIdle.transform.position + fwdDir * armLength + verticalOffset;

            GameObject lhBack = new GameObject("LH_Back");
            lhBack.transform.parent = handsTarget.transform;
            lhBack.transform.position = lhIdle.transform.position - fwdDir * armLength + verticalOffset;

            GameObject rhIdle = new GameObject("RH_Idle");
            rhIdle.transform.parent = handsTarget.transform;
            rhIdle.transform.position = hips.position + rightDir * (armLength * 0.6f);

            GameObject rhSide = new GameObject("RH_Side");
            rhSide.transform.parent = handsTarget.transform;
            rhSide.transform.position = rightHand.position + rightDir * armLength + verticalOffset;

            GameObject rhFront = new GameObject("RH_Front");
            rhFront.transform.parent = handsTarget.transform;
            rhFront.transform.position = rhIdle.transform.position + fwdDir * armLength + verticalOffset;

            GameObject rhBack = new GameObject("RH_Back");
            rhBack.transform.parent = handsTarget.transform;
            rhBack.transform.position = rhIdle.transform.position - fwdDir * armLength + verticalOffset;

            D_leftArm.Target.position = lhIdle.transform.position;
            D_rightArm.Target.position = rhIdle.transform.position;

            handsDrive.LeftHandTarget = D_leftArm.Target;
            handsDrive.RightHandTarget = D_rightArm.Target;

            handsDrive.bos = D_bos;
            handsDrive.ragdollManager = D_ragdollManager;
            handsDrive.Pelvis = hips;
            handsDrive.LH_Idle = lhIdle.transform;
            handsDrive.LH_Side = lhSide.transform;
            handsDrive.LH_Front = lhFront.transform;
            handsDrive.LH_Back = lhBack.transform;
            handsDrive.RH_Idle = rhIdle.transform;
            handsDrive.RH_Side = rhSide.transform;
            handsDrive.RH_Front = rhFront.transform;
            handsDrive.RH_Back = rhBack.transform;

            handsDrive.slideCurve = GetHandGraph();
        }

        private void SetUpRagdollManager(RagdollManager ragdollManager)
        {
            ragdollManager.jointSpringList = _jointSpringList;

            List<RagdollManager.PartTypeInfo> _partTypeList = new List<RagdollManager.PartTypeInfo>();

            RagdollManager.PartTypeInfo partSpine1 = new RagdollManager.PartTypeInfo(Spine1, Spine1.localRotation, RagdollManager.PartType.Spine1);
            RagdollManager.PartTypeInfo partSpine3 = new RagdollManager.PartTypeInfo(Spine3, Spine3.localRotation, RagdollManager.PartType.Spine3);
            RagdollManager.PartTypeInfo partLeftScapula = new RagdollManager.PartTypeInfo(leftScapula, leftScapula.localRotation, RagdollManager.PartType.leftScapula);
            RagdollManager.PartTypeInfo partRightScapula = new RagdollManager.PartTypeInfo(rightScapula, rightScapula.localRotation, RagdollManager.PartType.rightScapula);
            RagdollManager.PartTypeInfo partLeftToe = new RagdollManager.PartTypeInfo(leftToe, leftToe.localRotation, RagdollManager.PartType.leftToe);
            RagdollManager.PartTypeInfo partRightToe = new RagdollManager.PartTypeInfo(rightToe, rightToe.localRotation, RagdollManager.PartType.rightToe);
            RagdollManager.PartTypeInfo partLeftHand = new RagdollManager.PartTypeInfo(leftHand, leftHand.localRotation, RagdollManager.PartType.leftHand);
            RagdollManager.PartTypeInfo partRightHand = new RagdollManager.PartTypeInfo(rightHand, rightHand.localRotation, RagdollManager.PartType.rightHand);
            RagdollManager.PartTypeInfo partNeck= new RagdollManager.PartTypeInfo(neck, neck.localRotation, RagdollManager.PartType.neck);

            _partTypeList.Add(partSpine1);
            _partTypeList.Add(partSpine3);
            _partTypeList.Add(partLeftScapula);
            _partTypeList.Add(partRightScapula);
            _partTypeList.Add(partLeftToe);
            _partTypeList.Add(partRightToe);
            _partTypeList.Add(partLeftHand);
            _partTypeList.Add(partRightHand);
            _partTypeList.Add(partNeck);

            ragdollManager.partTypeList = _partTypeList;
        }
        private void SetUpLeg(InverseDynamic _leg, bool isleft)
        {
            if (isleft)
            {
                _leg.Upper = leftThigh;
                _leg.Lower = leftKnee;
                _leg.End = leftFoot;
                _leg.Target = new GameObject("LeftLegTarget").transform;
                _leg.Pole = new GameObject("LeftLegHint").transform;

                _leg.Target.hideFlags = HideFlags.HideInHierarchy;
                _leg.Pole.hideFlags = HideFlags.HideInHierarchy;

                _leg.Target.SetParent(hips);
                _leg.Pole.SetParent(hips);

                _leg.Target.position = leftFoot.position;
                _leg.Pole.position = leftThigh.transform.position + leftThigh.TransformDirection(Maths.GetAxisVector(L_legUp)).normalized;

                _leg.localDir = L_legDir;
                _leg.localPole = L_legPole;

            }
            else
            {
                _leg.Upper = rightThigh;
                _leg.Lower = rightKnee;
                _leg.End = rightFoot;
                _leg.Target = new GameObject("RightLegTarget").transform;
                _leg.Pole = new GameObject("RightLegHint").transform;

                _leg.Target.hideFlags = HideFlags.HideInHierarchy;
                _leg.Pole.hideFlags = HideFlags.HideInHierarchy;

                _leg.Target.SetParent(hips);
                _leg.Pole.SetParent(hips);

                _leg.Target.position = rightFoot.position;
                _leg.Pole.position = rightThigh.transform.position + rightThigh.TransformDirection(Maths.GetAxisVector(R_legUp)).normalized;

                _leg.localDir = R_legDir;
                _leg.localPole = R_legPole;
            }

        }
        private void SetUpArm(InverseDynamic _arm, bool isleft)
        {
            if (isleft)
            {
                _arm.Upper = leftArm;
                _arm.Lower = leftElbow;
                _arm.End = leftHand;
                _arm.Target = new GameObject("LeftHandTarget").transform;
                _arm.Pole = new GameObject("LeftHandHint").transform;

                _arm.Target.hideFlags = HideFlags.HideInHierarchy;
                _arm.Pole.hideFlags = HideFlags.HideInHierarchy;

                _arm.Target.SetParent(hips);
                _arm.Pole.SetParent(hips);

                _arm.Target.position = leftHand.position;
                _arm.Pole.position = leftArm.transform.position + leftArm.TransformDirection(Maths.GetAxisVector(L_armUp)).normalized;
                _arm.localDir = L_armDir;
                _arm.localPole = L_armPole;
            }
            else
            {
                _arm.Upper = rightArm;
                _arm.Lower = rightElbow;
                _arm.End = rightHand;
                _arm.Target = new GameObject("RightHandTarget").transform;
                _arm.Pole = new GameObject("RightHandHint").transform;

                _arm.Target.hideFlags = HideFlags.HideInHierarchy;
                _arm.Pole.hideFlags = HideFlags.HideInHierarchy;

                _arm.Target.SetParent(hips);
                _arm.Pole.SetParent(hips);

                _arm.Target.position = rightHand.position;
                _arm.Pole.position = rightArm.transform.position + rightArm.TransformDirection(Maths.GetAxisVector(R_armUp)).normalized;
                _arm.localDir = R_armDir;
                _arm.localPole = R_armPole;
            }

        }
        private void SetUpBehaviour(DynamicBehaviour _behaviour, InverseDynamic _Rleg, InverseDynamic _Lleg, InverseDynamic _Rarm, InverseDynamic _Larm)
        {
            float _legSpring = totalMass * 25f;
            Vector3 _upRight = hips.InverseTransformDirection(Vector3.down);

            Vector3 kneeLength = (leftKnee.position - leftThigh.position);
            Vector3 footLength = (leftFoot.position - leftKnee.position);

            float _maxVel = (kneeLength.magnitude + footLength.magnitude) / 0.19f;
            float _tolerate = (kneeLength.magnitude + footLength.magnitude) / 8.2f;
            float _footSpacing = (kneeLength.magnitude + footLength.magnitude) / 5.45f;

            _behaviour.Body = hips.transform;
            _behaviour.hipsDrive = D_hipsDrive;
            _behaviour.bos = D_bos;
            _behaviour.LeftLeg = _Lleg;
            _behaviour.RightLeg = _Rleg;
            _behaviour.LeftArm = _Larm;
            _behaviour.RightArm = _Rarm;
            _behaviour.B_right = rightAxis;
            _behaviour.B_up = upAxis;
            _behaviour.B_forward = fwdAxis;
            _behaviour.legSpring = _legSpring;
            _behaviour.upRight = _upRight;
            _behaviour.ragdollManager = D_ragdollManager;
            _behaviour.WeightGraph = GetWeightGraph();
            _behaviour.TimeGraph = GetTimeGraph();
            _behaviour.maxVel = _maxVel;
            _behaviour.tolerate = _tolerate;
            _behaviour.footSpacing = _footSpacing;
        }
        private void SetUpBOS(BOS _bos)
        {
            _bos.RightKnee = rightKnee;
            _bos.RightFoot = rightFoot;
            _bos.RightToe = rightToe;
            _bos.LeftKnee = leftKnee;
            _bos.LeftFoot = leftFoot;
            _bos.LeftToe = leftToe;
        }
        private void SetUpHipsDrive(HipsDrive _hipsDrive)
        {
            float spring = totalMass * 187.5f;
            float _hipsAngle = Vector3.SignedAngle(Vector3.up, hips.GetWorldDir(upAxis), hips.GetWorldDir(rightAxis));

            Vector3 kneeLength = (leftKnee.position - leftThigh.position);
            Vector3 footLength = (leftFoot.position - leftKnee.position);



            float _maxVel = (kneeLength.magnitude + footLength.magnitude) / 0.68f;

            _hipsDrive.Body = hips.transform;
            _hipsDrive.bos = D_bos;
            _hipsDrive.H_right = rightAxis;
            _hipsDrive.H_up = upAxis;
            _hipsDrive.H_forward = fwdAxis;
            _hipsDrive.H_spring = spring;
            _hipsDrive.hipsAngle = _hipsAngle;
            _hipsDrive.maxVel = _maxVel;
        }
        private void SetUpFootDet()
        {
            FootDetect RKdet = rightKnee.gameObject.AddComponent<FootDetect>();
            FootDetect LKdet = leftKnee.gameObject.AddComponent<FootDetect>();
            FootDetect RFdet = rightFoot.gameObject.AddComponent<FootDetect>();
            FootDetect LFdet = leftFoot.gameObject.AddComponent<FootDetect>();

            RKdet.RefObj = rightKnee;
            LKdet.RefObj = leftKnee;
            RFdet.RefObj = rightToe;
            LFdet.RefObj = leftToe;

            RKdet.upAxis = -R_legDir;
            LKdet.upAxis = -L_legDir;
            RFdet.upAxis = RTUp;
            LFdet.upAxis = LTUp;
        }
        private void SetUpHipsJoint(Transform _hips)
        {
            ConfigurableJoint hipsJoint = _hips.gameObject.AddComponent<ConfigurableJoint>();

            hipsJoint.xMotion = ConfigurableJointMotion.Free;
            hipsJoint.yMotion = ConfigurableJointMotion.Free;
            hipsJoint.zMotion = ConfigurableJointMotion.Free;

            hipsJoint.angularXMotion = ConfigurableJointMotion.Free;
            hipsJoint.angularYMotion = ConfigurableJointMotion.Free;
            hipsJoint.angularZMotion = ConfigurableJointMotion.Free;

            hipsJoint.axis = Maths.GetAxisVector(upAxis);
            hipsJoint.secondaryAxis = Maths.GetAxisVector(fwdAxis);

            JointDrive YZdrive = new JointDrive();
            YZdrive.positionSpring = totalMass * 187.5f;
            YZdrive.positionDamper = totalMass * 18.75f;
            YZdrive.maximumForce = float.MaxValue;

            JointDrive Xdrive = new JointDrive();
            Xdrive.positionSpring = totalMass * 12.5f;
            Xdrive.positionDamper = totalMass * 3.75f;
            Xdrive.maximumForce = float.MaxValue;

            hipsJoint.rotationDriveMode = RotationDriveMode.XYAndZ;

            hipsJoint.angularYZDrive = YZdrive;
            hipsJoint.angularXDrive = Xdrive;

            RagdollManager.JointSpringInfo jointInfos = new RagdollManager.JointSpringInfo(hipsJoint, RagdollManager.JointType.hips, YZdrive.positionSpring, YZdrive.positionDamper);
            _jointSpringList.Add(jointInfos);
        }
        private void SetUpSpineJoint(Transform _middleSpine)
        {
            ConfigurableJoint spineJoint = _middleSpine.gameObject.AddComponent<ConfigurableJoint>();

            Vector3 localRight = hips.TransformDirection(Maths.GetAxisVector(rightAxis));
            Vector3 localFwd = hips.TransformDirection(Maths.GetAxisVector(fwdAxis));

            int axis = Maths.GetDominantAxis(head.InverseTransformDirection(localRight));
            int secaxis = Maths.GetDominantAxis(head.InverseTransformDirection(localFwd));

            spineJoint.axis = Maths.GetAxisVector(axis);
            spineJoint.secondaryAxis = Maths.GetAxisVector(secaxis);

            spineJoint.connectedBody = hips.GetComponent<Rigidbody>();

            spineJoint.xMotion = ConfigurableJointMotion.Locked;
            spineJoint.yMotion = ConfigurableJointMotion.Locked;
            spineJoint.zMotion = ConfigurableJointMotion.Locked;

            spineJoint.angularXMotion = ConfigurableJointMotion.Limited;
            spineJoint.angularYMotion = ConfigurableJointMotion.Limited;
            spineJoint.angularZMotion = ConfigurableJointMotion.Limited;

            SoftJointLimit xLimit = new SoftJointLimit();

            xLimit.limit = -20;
            spineJoint.lowAngularXLimit = xLimit;
            xLimit.limit = 20;
            spineJoint.highAngularXLimit = xLimit;
            xLimit.limit = 10;
            spineJoint.angularYLimit = xLimit;

            JointDrive drive = new JointDrive();
            drive.positionSpring = totalMass * 20f;
            drive.positionDamper = totalMass * 2f;
            drive.maximumForce = float.MaxValue;

            spineJoint.rotationDriveMode = RotationDriveMode.Slerp;

            spineJoint.slerpDrive = drive;

            RagdollManager.JointSpringInfo jointInfos = new RagdollManager.JointSpringInfo(spineJoint, RagdollManager.JointType.middleSpine, drive.positionSpring, drive.positionDamper);
            _jointSpringList.Add(jointInfos);

        }
        private void SetUpHeadJoint(Transform _head)
        {
            ConfigurableJoint headJoint = _head.gameObject.AddComponent<ConfigurableJoint>();

            Vector3 localRight = hips.TransformDirection(Maths.GetAxisVector(rightAxis));
            Vector3 localFwd = hips.TransformDirection(Maths.GetAxisVector(fwdAxis));

            int axis = Maths.GetDominantAxis(head.InverseTransformDirection(localRight));
            int secaxis = Maths.GetDominantAxis(head.InverseTransformDirection(localFwd));

            headJoint.axis = Maths.GetAxisVector(axis);
            headJoint.secondaryAxis = Maths.GetAxisVector(secaxis);

            headJoint.connectedBody = middleSpine.GetComponent<Rigidbody>();

            headJoint.xMotion = ConfigurableJointMotion.Locked;
            headJoint.yMotion = ConfigurableJointMotion.Locked;
            headJoint.zMotion = ConfigurableJointMotion.Locked;

            headJoint.angularXMotion = ConfigurableJointMotion.Limited;
            headJoint.angularYMotion = ConfigurableJointMotion.Limited;
            headJoint.angularZMotion = ConfigurableJointMotion.Limited;

            SoftJointLimit xLimit = new SoftJointLimit();

            xLimit.limit = -40;
            headJoint.lowAngularXLimit = xLimit;
            xLimit.limit = 25;
            headJoint.highAngularXLimit = xLimit;
            xLimit.limit = 25;
            headJoint.angularYLimit = xLimit;

            JointDrive drive = new JointDrive();
            drive.positionSpring = totalMass * 6.25f;
            drive.positionDamper = totalMass * 0.625f;
            drive.maximumForce = float.MaxValue;

            headJoint.rotationDriveMode = RotationDriveMode.Slerp;

            headJoint.slerpDrive = drive;

            RagdollManager.JointSpringInfo jointInfos = new RagdollManager.JointSpringInfo(headJoint, RagdollManager.JointType.head, drive.positionSpring, drive.positionDamper);
            _jointSpringList.Add(jointInfos);
        }
        private void SetUpArmJoint(Transform part, Transform to, bool isleft)
        {
            ConfigurableJoint armJoint = part.gameObject.AddComponent<ConfigurableJoint>();
            ConfigurableJoint elbowJoint = to.gameObject.AddComponent<ConfigurableJoint>();

            Vector3 toElbow = (to.position - part.position).normalized;

            if (!isleft)
            {
                toElbow = -toElbow;
            }

            Vector3 localfwd = hips.TransformDirection(Maths.GetAxisVector(fwdAxis));
            Vector3 localup = Vector3.Cross(toElbow, localfwd);

            Vector3 armUp = part.InverseTransformDirection(localup);
            Vector3 armFwd = part.InverseTransformDirection(localfwd);
            Vector3 armDir = part.InverseTransformDirection((to.position - part.position).normalized);

            int axis = Maths.GetDominantAxis(armUp);
            int secaxis = Maths.GetDominantAxis(armFwd);
            int dir = Maths.GetDominantAxis(armDir);

            if (isleft)
            {
                L_armPole = -secaxis;
                L_armDir = dir;
                L_armUp = axis;
            }
            else
            {
                R_armPole = -secaxis;
                R_armDir = dir;
                R_armUp = -axis;
                axis = -axis;
            }

            armJoint.axis = Maths.GetAxisVector(axis);
            armJoint.secondaryAxis = Maths.GetAxisVector(secaxis);

            Vector3 elbUp = to.InverseTransformDirection(localup);
            Vector3 elbFwd = to.InverseTransformDirection(localfwd);

            axis = Maths.GetDominantAxis(elbFwd);
            secaxis = Maths.GetDominantAxis(elbUp);

            if (!isleft)
            {
                axis = -axis;
            }

            elbowJoint.axis = Maths.GetAxisVector(axis);
            elbowJoint.secondaryAxis = Maths.GetAxisVector(secaxis);

            armJoint.connectedBody = middleSpine.gameObject.GetComponent<Rigidbody>();
            elbowJoint.connectedBody = part.gameObject.GetComponent<Rigidbody>();

            armJoint.xMotion = ConfigurableJointMotion.Locked;
            armJoint.yMotion = ConfigurableJointMotion.Locked;
            armJoint.zMotion = ConfigurableJointMotion.Locked;

            armJoint.angularXMotion = ConfigurableJointMotion.Limited;
            armJoint.angularYMotion = ConfigurableJointMotion.Limited;
            armJoint.angularZMotion = ConfigurableJointMotion.Limited;

            elbowJoint.xMotion = ConfigurableJointMotion.Locked;
            elbowJoint.yMotion = ConfigurableJointMotion.Locked;
            elbowJoint.zMotion = ConfigurableJointMotion.Locked;

            elbowJoint.angularXMotion = ConfigurableJointMotion.Limited;
            elbowJoint.angularYMotion = ConfigurableJointMotion.Locked;
            elbowJoint.angularZMotion = ConfigurableJointMotion.Locked;

            SoftJointLimit xLimit = new SoftJointLimit();
            xLimit.limit = -70;
            armJoint.lowAngularXLimit = xLimit;
            xLimit.limit = 50;
            armJoint.highAngularXLimit = xLimit;
            xLimit.limit = 90;
            armJoint.angularYLimit = xLimit;
            xLimit.limit = 60;
            armJoint.angularZLimit = xLimit;

            xLimit.limit = -90f;
            elbowJoint.lowAngularXLimit = xLimit;

            JointDrive drive = new JointDrive();
            drive.positionSpring = totalMass / 0.25f;
            drive.positionDamper = totalMass / 2.5f;
            drive.maximumForce = float.MaxValue;

            armJoint.rotationDriveMode = RotationDriveMode.Slerp;
            elbowJoint.rotationDriveMode = RotationDriveMode.Slerp;

            armJoint.slerpDrive = drive;

            if (isleft)
            {
                RagdollManager.JointSpringInfo jointInfos = new RagdollManager.JointSpringInfo(armJoint, RagdollManager.JointType.leftArm, drive.positionSpring, drive.positionDamper);
                _jointSpringList.Add(jointInfos);
            }
            else
            {
                RagdollManager.JointSpringInfo jointInfos = new RagdollManager.JointSpringInfo(armJoint, RagdollManager.JointType.rightArm, drive.positionSpring, drive.positionDamper);
                _jointSpringList.Add(jointInfos);
            }

            drive.positionSpring = totalMass / 0.8f;
            drive.positionDamper = totalMass / 4f;
            drive.maximumForce = float.MaxValue;

            elbowJoint.slerpDrive = drive;

            if (isleft)
            {
                RagdollManager.JointSpringInfo jointInfos = new RagdollManager.JointSpringInfo(elbowJoint, RagdollManager.JointType.leftElbow, drive.positionSpring, drive.positionDamper);
                _jointSpringList.Add(jointInfos);
            }
            else
            {
                RagdollManager.JointSpringInfo jointInfos = new RagdollManager.JointSpringInfo(elbowJoint, RagdollManager.JointType.rightElbow, drive.positionSpring, drive.positionDamper);
                _jointSpringList.Add(jointInfos);
            }
        }
        private void SetUpLegJoint(Transform part, Transform to, Transform end, bool isleft)
        {
            ConfigurableJoint legJoint = part.gameObject.AddComponent<ConfigurableJoint>();
            ConfigurableJoint kneeJoint = to.gameObject.AddComponent<ConfigurableJoint>();
            ConfigurableJoint endJoint = end.gameObject.AddComponent<ConfigurableJoint>();

            Vector3 localRight = part.InverseTransformDirection(hips.TransformDirection(Maths.GetAxisVector(rightAxis)));
            Vector3 localFwd = part.InverseTransformDirection(hips.TransformDirection(Maths.GetAxisVector(fwdAxis)));
            Vector3 localDir = part.InverseTransformDirection((to.position - part.position).normalized);

            Vector3 kneeLocalRight = to.InverseTransformDirection(hips.TransformDirection(Maths.GetAxisVector(rightAxis)));
            Vector3 kneeLocalFwd = to.InverseTransformDirection(hips.TransformDirection(Maths.GetAxisVector(fwdAxis)));

            Vector3 endLocalRight = end.InverseTransformDirection(hips.TransformDirection(Maths.GetAxisVector(rightAxis)));
            Vector3 endLocalFwd = end.InverseTransformDirection(hips.TransformDirection(Maths.GetAxisVector(fwdAxis)));

            int right = Maths.GetDominantAxis(localRight);
            int fwd = Maths.GetDominantAxis(localFwd);
            int dir = Maths.GetDominantAxis(localDir);

            if (isleft)
            {
                L_legPole = -right;
                L_legDir = dir;
                L_legUp = fwd;
            }
            else
            {
                R_legPole = -right;
                R_legDir = dir;
                R_legUp = fwd;
            }

            legJoint.axis = Maths.GetAxisVector(Maths.GetDominantAxis(localRight));
            legJoint.secondaryAxis = Maths.GetAxisVector(Maths.GetDominantAxis(localFwd));

            kneeJoint.axis = Maths.GetAxisVector(Maths.GetDominantAxis(kneeLocalRight));
            kneeJoint.secondaryAxis = Maths.GetAxisVector(Maths.GetDominantAxis(kneeLocalFwd));

            endJoint.axis = Maths.GetAxisVector(Maths.GetDominantAxis(endLocalRight));
            endJoint.secondaryAxis = Maths.GetAxisVector(Maths.GetDominantAxis(endLocalFwd));

            legJoint.connectedBody = hips.gameObject.GetComponent<Rigidbody>();
            kneeJoint.connectedBody = part.gameObject.GetComponent<Rigidbody>();
            endJoint.connectedBody = to.gameObject.GetComponent<Rigidbody>();

            legJoint.xMotion = ConfigurableJointMotion.Locked;
            legJoint.yMotion = ConfigurableJointMotion.Locked;
            legJoint.zMotion = ConfigurableJointMotion.Locked;

            legJoint.angularXMotion = ConfigurableJointMotion.Limited;
            legJoint.angularYMotion = ConfigurableJointMotion.Limited;
            legJoint.angularZMotion = ConfigurableJointMotion.Limited;

            kneeJoint.xMotion = ConfigurableJointMotion.Locked;
            kneeJoint.yMotion = ConfigurableJointMotion.Locked;
            kneeJoint.zMotion = ConfigurableJointMotion.Locked;

            kneeJoint.angularXMotion = ConfigurableJointMotion.Limited;
            kneeJoint.angularYMotion = ConfigurableJointMotion.Locked;
            kneeJoint.angularZMotion = ConfigurableJointMotion.Locked;

            endJoint.xMotion = ConfigurableJointMotion.Locked;
            endJoint.yMotion = ConfigurableJointMotion.Locked;
            endJoint.zMotion = ConfigurableJointMotion.Locked;

            endJoint.angularXMotion = ConfigurableJointMotion.Limited;
            endJoint.angularYMotion = ConfigurableJointMotion.Locked;
            endJoint.angularZMotion = ConfigurableJointMotion.Locked;

            SoftJointLimit xLimit = new SoftJointLimit();
            xLimit.limit = -45f;
            legJoint.lowAngularXLimit = xLimit;
            xLimit.limit = 90f;
            legJoint.highAngularXLimit = xLimit;
            xLimit.limit = 45f;
            legJoint.angularYLimit = xLimit;
            xLimit.limit = 60f;
            legJoint.angularZLimit = xLimit;

            xLimit.limit = -130f;
            kneeJoint.lowAngularXLimit = xLimit;

            xLimit.limit = -15f;
            endJoint.lowAngularXLimit = xLimit;
            xLimit.limit = 15f;
            endJoint.highAngularXLimit = xLimit;

            JointDrive drive = new JointDrive();
            drive.positionSpring = totalMass * 25f;
            drive.positionDamper = totalMass * 2.5f;
            drive.maximumForce = float.MaxValue;

            JointDrive Fdrive = new JointDrive();
            Fdrive.positionSpring = totalMass * 2.5f;
            Fdrive.positionDamper = totalMass * 0.25f;
            Fdrive.maximumForce = float.MaxValue;

            legJoint.rotationDriveMode = RotationDriveMode.Slerp;
            kneeJoint.rotationDriveMode = RotationDriveMode.Slerp;
            endJoint.rotationDriveMode = RotationDriveMode.Slerp;

            legJoint.slerpDrive = drive;
            kneeJoint.slerpDrive = drive;
            endJoint.slerpDrive = Fdrive;

            if (isleft)
            {
                RagdollManager.JointSpringInfo jointInfos1 = new RagdollManager.JointSpringInfo(legJoint, RagdollManager.JointType.leftThigh, drive.positionSpring, drive.positionDamper);
                RagdollManager.JointSpringInfo jointInfos2 = new RagdollManager.JointSpringInfo(kneeJoint, RagdollManager.JointType.leftKnee, drive.positionSpring, drive.positionDamper);
                RagdollManager.JointSpringInfo jointInfos3 = new RagdollManager.JointSpringInfo(endJoint, RagdollManager.JointType.leftFoot, Fdrive.positionSpring, Fdrive.positionDamper);

                _jointSpringList.Add(jointInfos1);
                _jointSpringList.Add(jointInfos2);
                _jointSpringList.Add(jointInfos3);
            }
            else
            {
                RagdollManager.JointSpringInfo jointInfos1 = new RagdollManager.JointSpringInfo(legJoint, RagdollManager.JointType.rightThigh, drive.positionSpring, drive.positionDamper);
                RagdollManager.JointSpringInfo jointInfos2 = new RagdollManager.JointSpringInfo(kneeJoint, RagdollManager.JointType.rightKnee, drive.positionSpring, drive.positionDamper);
                RagdollManager.JointSpringInfo jointInfos3 = new RagdollManager.JointSpringInfo(endJoint, RagdollManager.JointType.rightFoot, Fdrive.positionSpring, Fdrive.positionDamper);

                _jointSpringList.Add(jointInfos1);
                _jointSpringList.Add(jointInfos2);
                _jointSpringList.Add(jointInfos3);
            }

        }

        private void SetUpArmCollider(Transform part, Transform to, Transform end)
        {
            CapsuleCollider Armcollider = part.gameObject.AddComponent<CapsuleCollider>();
            CapsuleCollider Elbowcollider = to.gameObject.AddComponent<CapsuleCollider>();

            Vector3 direction = to.position - part.position;
            Vector3 elbowdir = end.position - to.position;
            
            Vector3 globalScale = GetGlobalScale(part);

            Vector3 inverseScale = new Vector3(
                1f / globalScale.x,
                1f / globalScale.y,
                1f / globalScale.z
            );

            direction = Vector3.Scale(direction, inverseScale);
            elbowdir = Vector3.Scale(elbowdir, inverseScale);

            float armlength = direction.magnitude;
            float elbowlength = elbowdir.magnitude * 1.4f;

            Armcollider.height = armlength;
            Armcollider.radius = armlength / 4.35f;

            Elbowcollider.height = elbowlength;
            Elbowcollider.radius = elbowlength / 6f;

            direction = direction.normalized;

            float dotX = Vector3.Dot(direction, part.right);
            float dotY = Vector3.Dot(direction, part.up);
            float dotZ = Vector3.Dot(direction, part.forward);

            if (Mathf.Abs(dotX) > Mathf.Abs(dotY) && Mathf.Abs(dotX) > Mathf.Abs(dotZ))
            {
                Armcollider.direction = 0;
                Elbowcollider.direction = 0;
                if (dotX > 0)
                {
                    Armcollider.center = new Vector3(armlength / 2, 0, 0);
                    Elbowcollider.center = new Vector3(elbowlength / 2, 0, 0);
                }
                else
                {
                    Armcollider.center = new Vector3(-armlength / 2, 0, 0);
                    Elbowcollider.center = new Vector3(-elbowlength / 2, 0, 0);
                }
            }
            else if (Mathf.Abs(dotY) > Mathf.Abs(dotZ))
            {
                Armcollider.direction = 1;
                Elbowcollider.direction = 1;

                if (dotY > 0)
                {
                    Armcollider.center = new Vector3(0, armlength / 2, 0);
                    Elbowcollider.center = new Vector3(0, elbowlength / 2, 0);
                }
                else
                {
                    Armcollider.center = new Vector3(0, -armlength / 2, 0);
                    Elbowcollider.center = new Vector3(0, -elbowlength / 2, 0);
                }
            }
            else
            {
                Armcollider.direction = 2;
                Elbowcollider.direction = 2;

                if (dotZ > 0)
                {
                    Armcollider.center = new Vector3(0, 0, armlength / 2);
                    Elbowcollider.center = new Vector3(0, 0, elbowlength / 2);
                }
                else
                {
                    Armcollider.center = new Vector3(0, 0, -armlength / 2);
                    Elbowcollider.center = new Vector3(0, 0, -elbowlength / 2);
                }
            }
        }

        private void SetUpLegCollider(Transform part, Transform mid, Transform to, Transform toe, bool isleft)
        {
            CapsuleCollider Thighcollider = part.gameObject.AddComponent<CapsuleCollider>();
            CapsuleCollider Kneecollider = mid.gameObject.AddComponent<CapsuleCollider>();
            CapsuleCollider toecollider = toe.gameObject.AddComponent<CapsuleCollider>();

            Vector3 direction = mid.position - part.position;

            Vector3 globalScale = GetGlobalScale(part);

            Vector3 inverseScale = new Vector3(
                1f / globalScale.x,
                1f / globalScale.y,
                1f / globalScale.z
            );

            direction = Vector3.Scale(direction, inverseScale);

            float thighlength = direction.magnitude;
            float kneelength;

            Vector3 localPos = mid.InverseTransformPoint(toe.position);

            if (Mathf.Abs(localPos.x) > Mathf.Abs(localPos.y) && Mathf.Abs(localPos.x) > Mathf.Abs(localPos.z))
            {
                kneelength = Mathf.Abs(localPos.x);
            }
            else if (Mathf.Abs(localPos.y) > Mathf.Abs(localPos.z))
            {
                kneelength = Mathf.Abs(localPos.y);
            }
            else
            {
                kneelength = Mathf.Abs(localPos.z);
            }
            kneelength *= 1.08f;

            Vector3 Footdist = toe.position - to.position;
            Footdist = Vector3.Scale(Footdist, inverseScale);

            toecollider.height = Footdist.magnitude / 0.8f;
            toecollider.radius = Footdist.magnitude / 3.2f;
            float toeupdist = toecollider.radius / 2f;

            Vector3 toefwd = toe.InverseTransformDirection(hips.TransformDirection(Maths.GetAxisVector(fwdAxis)));
            Vector3 toeUp = toe.InverseTransformDirection(hips.TransformDirection(Maths.GetAxisVector(upAxis)));

            if (isleft)
            {
                LTUp = Maths.GetDominantAxis(toeUp);
            }
            else
            {
                RTUp = Maths.GetDominantAxis(toeUp);
            }

            if (Mathf.Abs(toefwd.x) > Mathf.Abs(toefwd.y) && Mathf.Abs(toefwd.x) > Mathf.Abs(toefwd.z))
            {
                toecollider.direction = 0;
            }
            else if (Mathf.Abs(toefwd.y) > Mathf.Abs(toefwd.z))
            {
                toecollider.direction = 1;
            }
            else
            {
                toecollider.direction = 2;
            }

            if (Mathf.Abs(toeUp.x) > Mathf.Abs(toeUp.y) && Mathf.Abs(toeUp.x) > Mathf.Abs(toeUp.z))
            {
                if (toeUp.x > 0)
                {
                    toecollider.center = Vector3.right * toeupdist;
                }
                else
                {
                    toecollider.center = -Vector3.right * toeupdist;
                }
            }
            else if (Mathf.Abs(toeUp.y) > Mathf.Abs(toeUp.z))
            {
                if (toeUp.y > 0)
                {
                    toecollider.center = Vector3.up * toeupdist;
                }
                else
                {
                    toecollider.center = -Vector3.up * toeupdist;
                }
            }
            else
            {
                if (toeUp.z > 0)
                {
                    toecollider.center = Vector3.forward * toeupdist;
                }
                else
                {
                    toecollider.center = -Vector3.forward * toeupdist;
                }
            }

            Thighcollider.height = thighlength;
            Thighcollider.radius = thighlength / 4.25f;

            Kneecollider.height = kneelength;
            Kneecollider.radius = kneelength / 6.5f;

            direction = direction.normalized;

            float dotX = Vector3.Dot(direction, part.right);
            float dotY = Vector3.Dot(direction, part.up);
            float dotZ = Vector3.Dot(direction, part.forward);

            if (Mathf.Abs(dotX) > Mathf.Abs(dotY) && Mathf.Abs(dotX) > Mathf.Abs(dotZ))
            {
                Thighcollider.direction = 0; 
                Kneecollider.direction = 0;
                if (dotX > 0)
                {
                    Thighcollider.center = new Vector3(thighlength / 2, 0, 0);
                    Kneecollider.center = new Vector3(kneelength / 2, 0, 0);
                }
                else
                {
                    Thighcollider.center = new Vector3(-thighlength / 2, 0, 0);
                    Kneecollider.center = new Vector3(-kneelength / 2, 0, 0);
                }
            }
            else if (Mathf.Abs(dotY) > Mathf.Abs(dotZ))
            {
                Thighcollider.direction = 1;
                Kneecollider.direction = 1;

                if (dotY > 0)
                {
                    Thighcollider.center = new Vector3(0, thighlength / 2, 0);
                    Kneecollider.center = new Vector3(0, kneelength / 2, 0);
                }
                else
                {
                    Thighcollider.center = new Vector3(0, -thighlength / 2, 0);
                    Kneecollider.center = new Vector3(0, -kneelength / 2, 0);
                }
            }
            else
            {
                Thighcollider.direction = 2; 
                Kneecollider.direction = 2;

                if (dotZ > 0)
                {
                    Thighcollider.center = new Vector3(0, 0, thighlength / 2);
                    Kneecollider.center = new Vector3(0, 0, kneelength / 2);
                }
                else
                {
                    Thighcollider.center = new Vector3(0, 0, -thighlength / 2);
                    Kneecollider.center = new Vector3(0, 0, -kneelength / 2);
                }
            }
        }

        private void SetUpPelvisCollider(Transform pelvis)
        {
            Vector3 armVector = rightArm.position - leftArm.position;
            Vector3 globalScale = GetGlobalScale(pelvis);

            Vector3 inverseScale = new Vector3(
                1f / globalScale.x,
                1f / globalScale.y,
                1f / globalScale.z
            );

            armVector = Vector3.Scale(armVector, inverseScale);
            float width = armVector.magnitude;
            float length = armVector.magnitude / 1.68f;

            Vector3 localRight = pelvis.InverseTransformDirection(armVector.normalized);
            rightAxis = Maths.GetDominantAxis(localRight);

            Vector3 spineToThigh = middleSpine.position - (leftThigh.position + rightThigh.position) / 2f;
            Vector3 localUp = pelvis.InverseTransformDirection(spineToThigh.normalized);
            upAxis = Maths.GetDominantAxis(localUp);

            Vector3 localForward = Vector3.Cross(
                Maths.GetAxisVector(rightAxis),
                Maths.GetAxisVector(upAxis)
            );
            fwdAxis = Maths.GetDominantAxis(localForward);

            Vector3 armstoSpine = ((rightArm.position + leftArm.position) / 2) - middleSpine.position;

            float Pheight = Mathf.Abs(Vector3.Dot(Vector3.Scale(spineToThigh, inverseScale), pelvis.TransformDirection(Maths.GetAxisVector(upAxis))));
            float Sheight = Mathf.Abs(Vector3.Dot(Vector3.Scale(armstoSpine, inverseScale), pelvis.TransformDirection(Maths.GetAxisVector(upAxis))));


            Vector3 Pcenter = (middleSpine.position + (leftThigh.position + rightThigh.position) / 2f) / 2f;
            Vector3 Scenter = (((rightArm.position + leftArm.position) / 2f) + middleSpine.position) / 2f;

            Pcenter = pelvis.InverseTransformPoint(Pcenter);
            Scenter = middleSpine.InverseTransformPoint(Scenter);

            BoxCollider Pcollider = pelvis.gameObject.AddComponent<BoxCollider>();
            BoxCollider Scollider = middleSpine.gameObject.AddComponent<BoxCollider>();

            Pcollider.size = new Vector3(
            Mathf.Abs(rightAxis) == 1 ? width : (Mathf.Abs(upAxis) == 1 ? Pheight : length), 
            Mathf.Abs(rightAxis) == 2 ? width : (Mathf.Abs(upAxis) == 2 ? Pheight : length),  
            Mathf.Abs(rightAxis) == 3 ? width : (Mathf.Abs(upAxis) == 3 ? Pheight : length)   
            );
            Pcollider.center = Pcenter;

            Scollider.size = new Vector3(
                Mathf.Abs(rightAxis) == 1 ? width : (Mathf.Abs(upAxis) == 1 ? Sheight : length), 
                Mathf.Abs(rightAxis) == 2 ? width : (Mathf.Abs(upAxis) == 2 ? Sheight : length),  
                Mathf.Abs(rightAxis) == 3 ? width : (Mathf.Abs(upAxis) == 3 ? Sheight : length)  
            );
            Scollider.center = Scenter;
        }

        private void SetUpHeadCollider(Transform _head)
        {
            SphereCollider headCollider = _head.gameObject.AddComponent<SphereCollider>();

            Vector3 direction = _head.position - middleSpine.position;
            Vector3 localup = _head.InverseTransformDirection(direction.normalized);

            int upAxis = Maths.GetDominantAxis(localup);

            Vector3 globalScale = GetGlobalScale(_head);

            Vector3 inverseScale = new Vector3(
                1f / globalScale.x,
                1f / globalScale.y,
                1f / globalScale.z
            );

            direction = Vector3.Scale(direction, inverseScale);

            headCollider.radius = direction.magnitude / 3f;
            float axisdist = headCollider.radius;
            headCollider.center = new Vector3(
                Mathf.Abs(upAxis) == 1 ? (upAxis > 0 ? axisdist : -axisdist) : 0,
                Mathf.Abs(upAxis) == 2 ? (upAxis > 0 ? axisdist : -axisdist) : 0,
                Mathf.Abs(upAxis) == 3 ? (upAxis > 0 ? axisdist : -axisdist) : 0
                );

        }

        private void AddRigidbody(Transform part, string partName)
        {
            if (!part.GetComponent<Rigidbody>())
            {
                Rigidbody rb = part.gameObject.AddComponent<Rigidbody>();
                rb.isKinematic = true;

                if (partName.Contains("Head"))
                {
                    rb.mass = totalMass * 0.07551f;
                }
                else if (partName.Contains("Arm") && !partName.Contains("Elbow"))
                {
                    rb.mass = totalMass * 0.025f;
                }
                else if (partName.Contains("Elbow"))
                {
                    rb.mass = totalMass * 0.02193f;
                }
                else if (partName.Contains("Thigh") || partName.Contains("Knee")) 
                {
                    rb.mass = totalMass * 0.11327f;
                }
                else if (partName.Contains("Hips") || partName.Contains("Spine"))
                {
                    rb.mass = totalMass * 0.18878f;
                }
            }
        }

        private AnimationCurve GetWeightGraph()
        {
           AnimationCurve weightCurve = new AnimationCurve(
           new Keyframe(0f, 0.8f),
           new Keyframe(0.32f, 0.3f),
           new Keyframe(1f, 0.3f)
           );

            AnimationUtility.SetKeyLeftTangentMode(weightCurve, 0, AnimationUtility.TangentMode.Linear);
            AnimationUtility.SetKeyLeftTangentMode(weightCurve, 1, AnimationUtility.TangentMode.Linear);
            AnimationUtility.SetKeyLeftTangentMode(weightCurve, 2, AnimationUtility.TangentMode.Linear);
            AnimationUtility.SetKeyRightTangentMode(weightCurve, 0, AnimationUtility.TangentMode.Linear);
            AnimationUtility.SetKeyRightTangentMode(weightCurve, 1, AnimationUtility.TangentMode.Linear);
            AnimationUtility.SetKeyRightTangentMode(weightCurve, 2, AnimationUtility.TangentMode.Linear);

            return weightCurve;
        }

        private AnimationCurve GetHandGraph()
        {
            AnimationCurve handCurve = new AnimationCurve(
                new Keyframe(0f, 0f),
                new Keyframe(0.027f, 0.65f),
                new Keyframe(0.1f, 1f)
            );

            return handCurve;
        }

        private AnimationCurve GetTimeGraph()
        {
            AnimationCurve timeCurve = new AnimationCurve(
            new Keyframe(0f, 0.18f),
            new Keyframe(0.2f, 0.32f),
            new Keyframe(1f, 0.32f)
            );

            AnimationUtility.SetKeyLeftTangentMode(timeCurve, 0, AnimationUtility.TangentMode.Linear);
            AnimationUtility.SetKeyLeftTangentMode(timeCurve, 1, AnimationUtility.TangentMode.Linear);
            AnimationUtility.SetKeyLeftTangentMode(timeCurve, 2, AnimationUtility.TangentMode.Linear);
            AnimationUtility.SetKeyRightTangentMode(timeCurve, 0, AnimationUtility.TangentMode.Linear);
            AnimationUtility.SetKeyRightTangentMode(timeCurve, 1, AnimationUtility.TangentMode.Linear);
            AnimationUtility.SetKeyRightTangentMode(timeCurve, 2, AnimationUtility.TangentMode.Linear);

            return timeCurve;
        }
        Vector3 GetGlobalScale(Transform transform)
        {
            Vector3 scale = transform.localScale;
            Transform parent = transform.parent;

            while (parent != null)
            {
                scale = Vector3.Scale(scale, parent.localScale);
                parent = parent.parent;
            }

            return scale;
        }

    }
}

