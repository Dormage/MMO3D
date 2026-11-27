using UnityEngine;

namespace DynamicRagdoll
{
    public class InverseDynamic : MonoBehaviour
    {
        public Transform Upper;
        public Transform Lower;
        public Transform End;

        public Transform Target;
        public Transform Pole;

        public float KneeWeight = 1f;

        private ConfigurableJoint UpperJoint;
        private ConfigurableJoint LowerJoint;
        private ConfigurableJoint EndJoint;

        private float a;
        private float b;
        private float c;
        private Vector3 en;

        private Vector3 currentTarget;

        private Quaternion startingRot_U;
        private Quaternion startingRot_L;
        private Quaternion startingRot_E;

        // Bind pozunda kurulan IK referans çatısı ile kemiğin gerçek rotasyonu arasındaki
        // fark. Çalışma anında rotasyonu bu fark üzerinden kurduğumuz için uzuv ekseni
        // hiçbir koşulda hedeften kopamaz ve sol/sağ (mirror) rig farkları kendiliğinden
        // doğru çözülür.
        private Quaternion ikOffset_U;
        private Quaternion ikOffset_L;

        // Target ile Pole aynı doğruya düştüğünde bükülme düzlemi tanımsız kalır;
        // o karelerde son geçerli normali kullanmak için saklıyoruz.
        private Vector3 lastBendNormal = Vector3.up;
        private bool bendNormalReady;

        public float legLength { get; private set; }

        [HideInInspector]
        public FootDetect det;

        private Transform ghostUpper;
        private Transform ghostLower;
        private Transform ghostEnd;

        [HideInInspector]
        public int localDir;
        [HideInInspector]
        public int localPole;

        private void OnDestroy()
        {
            Destroy(ghostUpper);
            Destroy(ghostLower);
            Destroy(ghostEnd);
        }
        private void Awake()
        {
            Init();

            UpperJoint = Upper.GetComponent<ConfigurableJoint>();
            LowerJoint = Lower.GetComponent<ConfigurableJoint>();
            EndJoint = End.GetComponent<ConfigurableJoint>();

            startingRot_U = ghostUpper.localRotation;
            startingRot_L = ghostLower.localRotation;
            startingRot_E = ghostEnd.localRotation;

            legLength = (Upper.position - Lower.position).magnitude + (Lower.position - End.position).magnitude;
            det = End.GetComponent<FootDetect>();

            CacheIKOffsets();
        }
        private void OnEnable()
        {
            if (UpperJoint != null && LowerJoint != null)
            {
                CacheIKOffsets();
            }
        }
        private void CacheIKOffsets()
        {
            Vector3 restBendNormal = GetBendNormal(ghostUpper.position, End.position, Pole.position);

            ikOffset_U = Quaternion.Inverse(Quaternion.LookRotation(End.position - ghostUpper.position, restBendNormal)) * ghostUpper.rotation;
            ikOffset_L = Quaternion.Inverse(Quaternion.LookRotation(End.position - ghostLower.position, restBendNormal)) * ghostLower.rotation;
        }
        private void Start()
        {
            
        }

        private void FixedUpdate()
        {
            ManipulateFootIK();
            CalculateDynamics();
        }
        private void Init()
        {
            ghostUpper = new GameObject("GhostThigh").transform;
            ghostUpper.position = Upper.position;
            ghostUpper.rotation = Upper.rotation;
            ghostUpper.localScale = Upper.localScale;
            ghostUpper.SetParent(Upper.parent);
            ghostUpper.hideFlags = HideFlags.HideInHierarchy;

            ghostLower = new GameObject("GhostShin").transform;
            ghostLower.position = Lower.position;
            ghostLower.rotation = Lower.rotation;
            ghostLower.localScale = Lower.localScale;
            ghostLower.SetParent(ghostUpper);
            ghostLower.hideFlags = HideFlags.HideInHierarchy;

            ghostEnd = new GameObject("GhostFoot").transform;
            ghostEnd.position = End.position;
            ghostEnd.rotation = End.rotation;
            ghostEnd.localScale = End.localScale;
            ghostEnd.SetParent(ghostLower);
            ghostEnd.hideFlags = HideFlags.HideInHierarchy;

        }

        private void ManipulateFootIK()
        {
            if (KneeWeight < 0.2f)
            {
                KneeWeight = 0.2f;
            }
            if (KneeWeight > 1f)
            {
                KneeWeight = 1f;
            }

            currentTarget = (Target.position - ghostUpper.position).normalized * legLength * KneeWeight + ghostUpper.position;
        }
        private void CalculateDynamics()
        {
            a = ghostLower.localPosition.magnitude;
            b = ghostEnd.localPosition.magnitude;
            c = Vector3.Distance(ghostUpper.position, currentTarget);
            en = GetBendNormal(ghostUpper.position, currentTarget, Pole.position);

            ghostUpper.rotation = Quaternion.LookRotation(currentTarget - ghostUpper.position, en) * ikOffset_U;
            ghostUpper.rotation = Quaternion.AngleAxis(-CosAngle(a, c, b), -en) * ghostUpper.rotation;

            ghostLower.rotation = Quaternion.LookRotation(currentTarget - ghostLower.position, en) * ikOffset_L;

            UpperJoint.SetTargetRotationLocal(ghostUpper.localRotation, startingRot_U);
            LowerJoint.SetTargetRotationLocal(ghostLower.localRotation, startingRot_L);

            if (EndJoint != null)
            {
                EndJoint.SetTargetRotationLocal(ghostEnd.localRotation, startingRot_E);
            }
        }

        private Vector3 GetBendNormal(Vector3 root, Vector3 target, Vector3 pole)
        {
            Vector3 normal = Vector3.Cross((target - root).normalized, (pole - root).normalized);

            if (normal.sqrMagnitude < 1e-6f)
            {
                return lastBendNormal;
            }

            normal.Normalize();

            // Hedef, pole hattının diğer tarafına geçtiğinde normal ham haliyle işaret
            // değiştirir; bu da dirseğin/dizin anlık olarak ters tarafa atmasına yol açar.
            // Bind pozunda belirlenen tarafı referans alarak süreklilik sağlıyoruz.
            if (bendNormalReady && Vector3.Dot(normal, lastBendNormal) < 0f)
            {
                normal = -normal;
            }

            lastBendNormal = normal;
            bendNormalReady = true;
            return normal;
        }

        private float CosAngle(float a, float b, float c)
        {
            if (!float.IsNaN(Mathf.Acos((-(c * c) + (a * a) + (b * b)) / (-2 * a * b)) * Mathf.Rad2Deg))
            {
                return Mathf.Acos((-(c * c) + (a * a) + (b * b)) / (2 * a * b)) * Mathf.Rad2Deg;
            }
            else
            {
                return 1;
            }
        }

    }

}
