using UnityEngine;

namespace DynamicRagdoll
{
    public class HipsDrive : MonoBehaviour
    {
        public Transform Body;
        private Transform ghostHips;

        public BOS bos;

        private ConfigurableJoint hipsDrive;
        private Rigidbody bodyRb;

        private Quaternion startingRot_H;

        public bool goBack = true;

        private LayerMask ignoreLayer;

        public Vector3 currentNormal;

        public float H_spring;
        public float H_weight = 1f;

        public int H_right;
        public int H_up;
        public int H_forward;

        public float hipsAngle;
        public float currentAngle;
        public float maxVel;

        [Tooltip("GhostHips'in asıl hipsin yönüne dönme hızı (derece/saniye). 0 = kapalı.")]
        public float yawFollowSpeed = 15f;

        private void FixedUpdate()
        {
            Drive();
        }
        private void Awake()
        {
            Init();

            startingRot_H = ghostHips.localRotation;
            bodyRb = Body.GetComponent<Rigidbody>();
        }
        private void OnDestroy()
        {
            Destroy(ghostHips.gameObject);
        }
        private void Init()
        {
            hipsDrive = Body.GetComponent<ConfigurableJoint>();

            ghostHips = new GameObject("GhostHips").transform;
            ghostHips.position = Vector3.zero;
            ghostHips.rotation = Body.rotation;
            ghostHips.SetParent(Body.parent);
            ghostHips.hideFlags = HideFlags.HideInHierarchy;

        }
        private void FollowBodyYaw()
        {
            if (yawFollowSpeed <= 0f)
                return;

            Vector3 ghostFwd = Maths.SetY(ghostHips.GetWorldDir(H_forward), 0f);
            Vector3 bodyFwd = Maths.SetY(Body.GetWorldDir(H_forward), 0f);

            // Gövde neredeyse dikeyken yatay izdüşüm gürültülü olur, yaw okunamaz.
            if (ghostFwd.sqrMagnitude < 0.01f || bodyFwd.sqrMagnitude < 0.01f)
                return;

            float yawError = Vector3.SignedAngle(ghostFwd, bodyFwd, Vector3.up);
            float maxStep = yawFollowSpeed * Time.fixedDeltaTime;
            float step = Mathf.Clamp(yawError, -maxStep, maxStep);

            ghostHips.rotation = Quaternion.AngleAxis(step, Vector3.up) * ghostHips.rotation;
        }
        private void Drive()
        {
            FollowBodyYaw();

            Quaternion currentRotation = ghostHips.rotation;
            Quaternion rotFwd = Quaternion.identity;

            if (Maths.SetY(bodyRb.linearVelocity, 0f).magnitude > maxVel)
            {
                goBack = Maths.DotProduct(Body.GetWorldDir(-H_forward), bodyRb.linearVelocity);
                Vector3 dir = bodyRb.linearVelocity.normalized;

                if (goBack)
                {
                    rotFwd = Quaternion.FromToRotation(ghostHips.GetWorldDir(H_forward), -dir);
                }
                else
                {
                    rotFwd = Quaternion.FromToRotation(ghostHips.GetWorldDir(H_forward), dir);
                }

                ghostHips.rotation = rotFwd * currentRotation;
                currentRotation = ghostHips.rotation;

            }
            Quaternion toUp = Quaternion.AngleAxis(hipsAngle, ghostHips.GetWorldDir(H_right));
            rotFwd = Quaternion.FromToRotation(ghostHips.GetWorldDir(H_up), Vector3.up);
            rotFwd = toUp * rotFwd;
            ghostHips.rotation = rotFwd * currentRotation;
            currentAngle = Vector3.Angle(ghostHips.GetWorldDir(H_up), Body.GetWorldDir(H_up));

            hipsDrive.SetTargetRotationLocal(ghostHips.localRotation, startingRot_H);

            if (bos.AllGrounded)
            {
                JointDrive YZDrive = hipsDrive.angularYZDrive;

                YZDrive.positionSpring = H_spring * H_weight;
                YZDrive.positionDamper = (H_spring / 10f) * H_weight;

                JointDrive XDrive = hipsDrive.angularXDrive;
                XDrive.positionSpring = H_spring / 150f;
                XDrive.positionDamper = (H_spring / 150f) * 0.5f;

                hipsDrive.angularYZDrive = YZDrive;
                hipsDrive.angularXDrive = XDrive;
            }
            else if (bos.BosActive && !bos.AllGrounded) 
            {
                JointDrive YZDrive = hipsDrive.angularYZDrive;

                YZDrive.positionSpring = H_spring / 2 * H_weight;
                YZDrive.positionDamper = (H_spring / 20f) * H_weight;

                JointDrive XDrive = hipsDrive.angularXDrive;
                XDrive.positionSpring = H_spring / 15f;
                XDrive.positionDamper = (H_spring / 15f) * 0.5f;

                hipsDrive.angularYZDrive = YZDrive;
                hipsDrive.angularXDrive = XDrive;
            }
            else
            {
                JointDrive YZDrive = hipsDrive.angularYZDrive;

                YZDrive.positionSpring = 0;
                YZDrive.positionDamper = 0;

                JointDrive XDrive = hipsDrive.angularXDrive;
                XDrive.positionSpring = 0;
                XDrive.positionDamper = 0;

                hipsDrive.angularYZDrive = YZDrive;
                hipsDrive.angularXDrive = XDrive;
            }

        }
    }

}
