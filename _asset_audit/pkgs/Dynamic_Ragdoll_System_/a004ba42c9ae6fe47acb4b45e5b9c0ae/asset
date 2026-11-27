using System.Collections;
using UnityEngine;
using UnityEngine.Events;

namespace DynamicRagdoll
{
    public class DynamicBehaviour : MonoBehaviour
    {
        [HideInInspector] public Transform Body;
        [HideInInspector] public InverseDynamic RightLeg;
        [HideInInspector] public InverseDynamic LeftLeg;
        [HideInInspector] public InverseDynamic RightArm;
        [HideInInspector] public InverseDynamic LeftArm;
        [HideInInspector] public BOS bos;
        [HideInInspector] public HipsDrive hipsDrive;
        [HideInInspector] public RagdollManager ragdollManager;
        [HideInInspector] public HandsDrive handsDrive;

        [Header("Hands Drive")]
        [Tooltip("[Work In Progress] Hand-drive feature is still under development. Disable if you encounter unexpected behaviour.")]
        public bool useHandsDrive = true;

        [HideInInspector] public AnimationCurve WeightGraph;
        [HideInInspector] public AnimationCurve TimeGraph;

        private Rigidbody bodyRb;
        private Coroutine checkBalance;

        [HideInInspector] public int B_right;
        [HideInInspector] public int B_up;
        [HideInInspector] public int B_forward;
        [HideInInspector] public float maxVel;

        [HideInInspector] public Vector3 upRight;
        [HideInInspector] private Vector3 getUpRight => Body.TransformDirection(upRight);

        [Tooltip("Balance likes 1.0 , Stagger Fall likes 0 - 0.1")]
        [Range(0f, 1f)]
        public float UpRightForce = 1f;

        [HideInInspector] public float tolerate = 0.1f;
        [HideInInspector] public float footSpacing = 0.15f;
        [HideInInspector] public float legSpring;

        [HideInInspector] public bool ragdollSit;
        private bool flag = false;
        private bool sitFlag = false;

        [Header("Ragdoll Fall and Stand Up Events")]
        [Tooltip("Invoked when the character falls down.")]
        public UnityEvent OnRagdollFall;
        [Tooltip("Invoked when the character regains balance and stands up.")]
        public UnityEvent OnRagdollStandUp;

        [HideInInspector] public bool r_Stepping;
        [HideInInspector] public bool l_Stepping;
        private bool stepping => r_Stepping || l_Stepping;
        private bool isLastLeft = false;
        private bool balance = false;

        private void Start()
        {
            SetMaterials();
            bodyRb = Body.GetComponent<Rigidbody>();
            ragdollManager.IgnoreCollisions();
            r_Stepping = false;
            l_Stepping = false;


        }

        private void FixedUpdate()
        {
            CtrlSit();
            ReHipsDrive();

            if (!ragdollSit)
            {
                Stagger();
                ReBalanceLeg();

                if (flag)
                {
                    ragdollManager.DynamicRagdoll();
                    flag = false;
                }
            }
            else if (!flag)
            {
                ragdollManager.NormalRagdoll();
                flag = true;
            }
        }
        private void OnValidate()
        {
            if (enabled)
            {
                if (LeftLeg != null)
                {
                    LeftLeg.enabled = true;
                }
                if (RightLeg != null)
                {
                    RightLeg.enabled = true;
                }
                if (RightArm != null)
                {
                    RightArm.enabled = true;
                }
                if (LeftArm != null)
                {
                    LeftArm.enabled = true;
                }
                if (hipsDrive != null)
                {
                    hipsDrive.enabled = true;
                }
                if (bos != null)
                {
                    bos.enabled = true;
                }
                if (handsDrive != null)
                {
                    handsDrive.enabled = useHandsDrive;
                }
                if (ragdollManager != null)
                {
                    ragdollManager.ReKinematic();
                }
            }
            else
            {
                if (LeftLeg != null)
                {
                    LeftLeg.enabled = false;
                }
                if (RightLeg != null)
                {
                    RightLeg.enabled = false;
                }
                if (RightArm != null)
                {
                    RightArm.enabled = false;
                }
                if (LeftArm != null)
                {
                    LeftArm.enabled = false;
                }
                if (hipsDrive != null)
                {
                    hipsDrive.enabled = false;
                }
                if (bos != null)
                {
                    bos.enabled = false;
                }
                if (handsDrive != null)
                {
                    handsDrive.enabled = false;
                }
                if (ragdollManager != null)
                {
                    ragdollManager.DoKinematic();
                }
            }
        }
        private void OnEnable()
        {
            LeftLeg.enabled = true;
            RightLeg.enabled = true;
            RightArm.enabled = true;
            LeftArm.enabled = true;
            hipsDrive.enabled = true;
            bos.enabled = true;
            if (handsDrive != null)
            {
                handsDrive.enabled = useHandsDrive;
            }
            ragdollManager.ReKinematic();
            ragdollManager.BackTPos();
        }
        private void OnDisable()
        {
            LeftLeg.enabled = false;
            RightLeg.enabled = false;
            RightArm.enabled = false;
            LeftArm.enabled = false;
            hipsDrive.enabled = false;
            bos.enabled = false;
            if (handsDrive != null)
            {
                handsDrive.enabled = false;
            }
            ragdollManager.DoKinematic();
        }
        
        private void ReBalanceLeg()
        {
            if (!r_Stepping)
            {
                RightLeg.Target.position = RightLeg.Upper.position + getUpRight * RightLeg.legLength;
                SetStiff(RightLeg.Upper.GetComponent<ConfigurableJoint>());
                SetStiff(RightLeg.Lower.GetComponent<ConfigurableJoint>());
            }
            else
            {
                SetSpring(RightLeg.Upper.GetComponent<ConfigurableJoint>());
                SetSpring(RightLeg.Lower.GetComponent<ConfigurableJoint>());
            }
            if (!l_Stepping)
            {
                LeftLeg.Target.position = LeftLeg.Upper.position + getUpRight * LeftLeg.legLength;
                SetStiff(LeftLeg.Upper.GetComponent<ConfigurableJoint>());
                SetStiff(LeftLeg.Lower.GetComponent<ConfigurableJoint>());
            }
            else
            {
                SetSpring(LeftLeg.Upper.GetComponent<ConfigurableJoint>());
                SetSpring(LeftLeg.Lower.GetComponent<ConfigurableJoint>());
            }
        }
        private void Stagger()
        {
            float footdist = (Maths.SetY(RightLeg.End.position, 0f) - Maths.SetY(LeftLeg.End.position, 0f)).magnitude;
            float comdist = Maths.COMtoBOSdist(bos.Bospoint, Body.position);

            float weight, time;
            bool legSit = LegUpRight(out weight, out time);

            bool stepBalance = balance && comdist >= tolerate;
            bool stepStagger = !balance && legSit;

            if (!stepping)
            {
                if (stepBalance)
                {
                    if (checkBalance != null)
                    {
                        StopCoroutine(checkBalance);
                        checkBalance = null;
                        r_Stepping = false;
                        l_Stepping = false;
                    }
                    StartCoroutine(StartStep(GetNextStepFoot(), time, weight));
                    balance = false;
                }
                else if (stepStagger)
                {
                    if (checkBalance != null)
                    {
                        StopCoroutine(checkBalance);
                        checkBalance = null;
                        r_Stepping = false;
                        l_Stepping = false;
                    }
                    StartCoroutine(StartStep(!isLastLeft, time * 2, weight));
                }
            }
        }

        private bool LegUpRight(out float _weight, out float _time)
        {
            Vector3 right = (RightLeg.End.position - RightLeg.Upper.position).normalized;
            Vector3 left = (LeftLeg.End.position - LeftLeg.Upper.position).normalized;

            _weight = 0f;
            _time = 0f;

            float rightDot = Vector3.Dot(Vector3.down, right);
            float leftDot = Vector3.Dot(Vector3.down, left);

            float finalDot = 0f;

            if (leftDot < rightDot)
            {
                finalDot = 1 - leftDot;
            }
            else
            {
                finalDot = 1 - rightDot;
            }

            _weight = WeightGraph.Evaluate(finalDot);
            _time = TimeGraph.Evaluate(finalDot);

            if (rightDot <= 0.995f || leftDot <= 0.995f)
            {
                return true;
            }
            
            return false;

        }
        private IEnumerator StartStep(bool isleftStepping, float steptime, float kneeBend)
        {
            float currenttime = 0f;
            float startknee = 0f;

            InverseDynamic leg = null;
            Vector3 target = Vector3.zero;

            if (isleftStepping)
            {
                l_Stepping = true;
                r_Stepping = false;
                leg = LeftLeg;
            }
            else
            {
                r_Stepping = true;
                l_Stepping = false;
                leg = RightLeg;
            }

            startknee = leg.KneeWeight;

            while (currenttime <= steptime)
            {
                currenttime += Time.fixedDeltaTime;

                if (isleftStepping)
                {
                    target = -Vector3.Reflect((RightLeg.End.position - RightLeg.Upper.position).normalized, Vector3.down);
                    leg.Target.position = LeftLeg.Upper.position + target;
                }
                else
                {
                    target = -Vector3.Reflect((LeftLeg.End.position - LeftLeg.Upper.position).normalized, Vector3.down);
                    leg.Target.position = RightLeg.Upper.position + target;
                }

                if (currenttime <= steptime * 0.5f)
                {
                    leg.KneeWeight = Mathf.Lerp(startknee, kneeBend, currenttime / (steptime * 0.5f));
                }
                else if (currenttime >= steptime * 0.5f)
                {
                    leg.KneeWeight = Mathf.Lerp(kneeBend, 0.99f, (currenttime - (steptime * 0.5f)) / (steptime * 0.5f));

                }
                yield return new WaitForFixedUpdate();
            }

            leg.KneeWeight = 0.99f;
            r_Stepping = false;
            l_Stepping = false;

            if (isleftStepping)
            {
                isLastLeft = true;
            }
            else
            {
                isLastLeft = false;
            }

            checkBalance = StartCoroutine(CheckBalance(1));
        }

        private IEnumerator CheckBalance(float time)
        {
            yield return new WaitForSeconds(time);
            balance = true;
            r_Stepping = false;
            l_Stepping = false;
            checkBalance = null;
        }
        private bool GetNextStepFoot()
        {
            Vector3 rightStep = Maths.GetNextStepPoint(LeftLeg.End.position, bodyRb.position);
            Vector3 leftStep = Maths.GetNextStepPoint(RightLeg.End.position, bodyRb.position);

            Vector3 flatRightLeg = Maths.SetY(RightLeg.End.position, 0f);
            Vector3 flatLeftLeg = Maths.SetY(LeftLeg.End.position, 0f);

            float rightSpacing = (flatLeftLeg - rightStep).magnitude;
            float leftSpacing = (flatRightLeg - leftStep).magnitude;

            bool right = Maths.DotProduct(Body.GetWorldDir(B_right), (rightStep - Body.position).normalized);
            bool left = Maths.DotProduct(Body.GetWorldDir(B_right), (leftStep - Body.position).normalized);

            if (right && left)
            {
                return false;
            }
            else if (!right && !left)
            {
                return true;
            }
            else if (leftSpacing > footSpacing && rightSpacing > footSpacing)
            {
                return rightSpacing >= leftSpacing;
            }
            else if (leftSpacing <= footSpacing && rightSpacing > footSpacing)
            {
                return false;
            }
            else if (rightSpacing <= footSpacing && leftSpacing > footSpacing)
            {
                return true;
            }
            else
            {
                return leftSpacing >= rightSpacing;
            }


        }
        private void SetStiff(ConfigurableJoint joint)
        {
            JointDrive drive = joint.slerpDrive;
            drive.positionSpring = 2000000;
            drive.positionDamper = 200000;
            drive.maximumForce = legSpring * 3.75f;
            joint.slerpDrive = drive;
        }
        private void SetSpring(ConfigurableJoint joint)
        {
            JointDrive drive = joint.slerpDrive;
            drive.positionSpring = legSpring;
            drive.positionDamper = legSpring / 10f;
            drive.maximumForce = float.MaxValue;
            joint.slerpDrive = drive;

        }
        private void CtrlSit()
        {
            bool shouldSit = Maths.SetY(bodyRb.linearVelocity, 0f).magnitude > maxVel || hipsDrive.currentAngle > 45f;

            if (shouldSit)
            {
                ragdollSit = true;
                hipsDrive.H_spring = 0;

                if (!sitFlag)
                {
                    sitFlag = true;
                    OnRagdollFall?.Invoke();
                }
            }
            else if (hipsDrive.currentAngle < 45f)
            {
                ragdollSit = false;
                hipsDrive.H_spring = ragdollManager.GetSpringByJointType(RagdollManager.JointType.hips).mainSpring;

                if (sitFlag)
                {
                    sitFlag = false;
                    OnRagdollStandUp?.Invoke();
                }
            }
        }
        private void ReHipsDrive()
        {
            hipsDrive.H_weight = UpRightForce;
        }
        private void SetMaterials()
        {
            PhysicsMaterial newMaterial = new PhysicsMaterial("CustomMaterial")
            {
                dynamicFriction = 0.6f,
                staticFriction = 0.6f,
                bounciness = 0f,
                frictionCombine = PhysicsMaterialCombine.Average, 
                bounceCombine = PhysicsMaterialCombine.Average 
            };
            RightLeg.Lower.gameObject.GetComponent<CapsuleCollider>().material = newMaterial;
            RightLeg.End.gameObject.GetComponentInChildren<CapsuleCollider>().material = newMaterial;
            LeftLeg.Lower.gameObject.GetComponent<CapsuleCollider>().material = newMaterial;
            LeftLeg.End.gameObject.GetComponentInChildren<CapsuleCollider>().material = newMaterial;
        }
    }

}
